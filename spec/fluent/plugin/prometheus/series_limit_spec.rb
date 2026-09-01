require 'spec_helper'

# The limit is exercised through the plugins as well, by the 'limits label
# expansion' shared examples. These examples stay at the Metric level, where a
# slot can be observed while an instrumentation is still running.
describe Fluent::Plugin::Prometheus::Metric do
  let(:registry) { ::Prometheus::Client::Registry.new }
  let(:max_series_per_metric) { 1 }
  let(:element) do
    Fluent::Config::Element.new(
      'metric', '',
      {
        'name' => 'limited',
        'type' => 'counter',
        'desc' => 'Something foo.',
        'key' => 'foo',
        'max_series_per_metric' => max_series_per_metric.to_s,
      },
      [Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, [])]
    )
  end
  # the label is a RecordAccessor, so no placeholder is expanded here
  let(:expander) { double('expander') }
  let(:metric) { Fluent::Plugin::Prometheus::Counter.new(element, registry, {}, {}) }
  # the client metric is registered by the Metric, so it has to be built before
  # the registry is asked for it
  let(:client_counter) do
    metric
    registry.get(:limited)
  end

  def instrument(path, value = 1)
    metric.instrument({'foo' => value, 'path' => path}, expander)
  end

  def build_metrics(*elements)
    Fluent::Plugin::Prometheus.parse_metrics_elements(
      Fluent::Config::Element.new('ROOT', '', {}, elements), registry, {}, {}
    )
  end

  # A <metric> section named 'shared', so that two of them instrument the same
  # client metric.
  def counter_element(limit, initlabels = nil)
    attributes = {
      'name' => 'shared',
      'type' => 'counter',
      'desc' => 'Something foo.',
      'key' => 'foo',
      'max_series_per_metric' => limit.to_s,
    }
    attributes['initialized'] = 'true' if initlabels

    Fluent::Config::Element.new(
      'metric', '', attributes,
      [Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, [])] +
        Array(initlabels).map { |path| Fluent::Config::Element.new('initlabels', '', {'path' => path}, []) }
    )
  end

  describe 'max_series_per_metric' do
    it 'refuses a new label set once the limit is reached' do
      instrument('/a')

      expect { instrument('/b') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
      expect(client_counter.values.keys).to eq([{path: '/a'}])
    end

    it 'gives the slot back when the instrumentation failed' do
      # a negative value makes Counter#increment raise, after the label set has
      # been reserved
      expect { instrument('/a', -1) }.to raise_error(ArgumentError)

      expect { instrument('/b') }.not_to raise_error
      expect(client_counter.values.keys).to eq([{path: '/b'}])
    end

    it 'does not take a slot for a value which is not a number' do
      # such a value is refused before the label set is reserved, so the metric
      # is left as if the record had never arrived
      expect { instrument('/a', 'not a number') }.to raise_error(ArgumentError)

      expect { instrument('/b') }.not_to raise_error
      expect(client_counter.values.keys).to eq([{path: '/b'}])
    end

    it 'takes the slot before instrumenting, so that concurrent calls cannot both pass' do
      # the slot has to be taken under the same lock as the check: taking it
      # after the client call would let both label sets through and expand the
      # metric beyond max_series_per_metric
      instrumenting = Queue.new
      resume = Queue.new
      allow(client_counter).to receive(:increment).and_wrap_original do |original, *args, **kwargs|
        instrumenting << true
        resume.pop
        original.call(*args, **kwargs)
      end

      first = Thread.new { instrument('/a') }
      instrumenting.pop # '/a' is inside the client call and holds the only slot

      expect { instrument('/b') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)

      resume << true
      first.join

      expect(client_counter.values.keys).to eq([{path: '/a'}])
    end

    # Two records which expand to the very same label set may be instrumented
    # at the same time: only one of them reserves the slot, the other one joins
    # that reservation. Giving the slot back on failure must then not drop a
    # label set the client already holds, otherwise a new one would take its
    # place and the metric would grow past max_series_per_metric.
    context 'when concurrent instrumentations share a label set' do
      # stalls the very first client call, so that a second instrumentation can
      # be run while the first one is still in flight
      def stall_first_instrumentation(entered, resume)
        stalled = false
        allow(client_counter).to receive(:increment).and_wrap_original do |original, *args, **kwargs|
          unless stalled
            stalled = true
            entered << true
            resume.pop
          end
          original.call(*args, **kwargs)
        end
      end

      it 'keeps the slot when the call which reserved it fails after another one succeeded' do
        entered = Queue.new
        resume = Queue.new
        stall_first_instrumentation(entered, resume)

        # a negative value is the one which fails inside the client call: a
        # value which is not a number never gets there, so it could not be
        # stalled
        failing = Thread.new do
          expect { instrument('/a', -1) }.to raise_error(ArgumentError)
        end
        entered.pop # {path: '/a'} is reserved by the record which is about to fail

        # joins that reservation and does give the label set to the client
        instrument('/a')

        resume << true
        failing.join

        # the client holds {path: '/a'}, so its slot must stay taken
        expect { instrument('/b') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
        expect(client_counter.values.keys).to eq([{path: '/a'}])
      end

      it 'keeps the slot when a call which joined a reservation fails' do
        entered = Queue.new
        resume = Queue.new
        stall_first_instrumentation(entered, resume)

        pending_call = Thread.new { instrument('/a') }
        entered.pop # {path: '/a'} is reserved and being instrumented

        # joins that reservation and fails in the client, without owning the slot
        expect { instrument('/a', -1) }.to raise_error(ArgumentError)

        resume << true
        pending_call.join

        expect { instrument('/b') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
        expect(client_counter.values.keys).to eq([{path: '/a'}])
      end

      it 'takes the slot back when a joined call succeeds after the reservation was released' do
        failing_entered = Queue.new
        failing_resume = Queue.new
        succeeding_entered = Queue.new
        succeeding_resume = Queue.new
        allow(client_counter).to receive(:increment).and_wrap_original do |original, *args, **kwargs|
          case kwargs[:by]
          when -1
            failing_entered << true
            failing_resume.pop
          when 2
            succeeding_entered << true
            succeeding_resume.pop
          end
          original.call(*args, **kwargs)
        end

        failing = Thread.new do
          expect { instrument('/a', -1) }.to raise_error(ArgumentError)
        end
        failing_entered.pop # {path: '/a'} is reserved

        succeeding = Thread.new { instrument('/a', 2) }
        succeeding_entered.pop # joined the reservation, the client has nothing yet

        failing_resume << true
        failing.join # the reservation is given back here

        succeeding_resume << true
        succeeding.join # from now on the client holds {path: '/a'}

        expect { instrument('/b') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
        expect(client_counter.values.keys).to eq([{path: '/a'}])
      end
    end
  end

  # Summary#observe increments the count and the sum one after the other, so a
  # value which is not a number leaves the count incremented and raises on the
  # sum. Giving the slot back would not take that half instrumented label set
  # away from the client, so the value is refused before it reaches either.
  describe 'a summary of a value which is not a number' do
    let(:element) do
      Fluent::Config::Element.new(
        'metric', '',
        {
          'name' => 'limited',
          'type' => 'summary',
          'desc' => 'Something foo.',
          'key' => 'foo',
          'max_series_per_metric' => max_series_per_metric.to_s,
        },
        [Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, [])]
      )
    end
    let(:metric) { Fluent::Plugin::Prometheus::Summary.new(element, registry, {}, {}) }
    let(:client_summary) do
      metric
      registry.get(:limited)
    end

    it 'leaves the client holding nothing' do
      expect { instrument('/a', 'not a number') }.to raise_error(ArgumentError)

      expect(client_summary.values).to be_empty
    end

    it 'does not take a slot' do
      expect { instrument('/a', 'not a number') }.to raise_error(ArgumentError)

      expect { instrument('/b', 2) }.not_to raise_error
      expect(client_summary.values.keys).to eq([{path: '/b'}])
    end
  end

  describe 'a metric name shared by two <metric> sections' do
    # both sections instrument the same client metric, so counting per section
    # would let it hold max_series_per_metric label sets twice over
    let(:max_series_per_metric) { 2 }
    let(:other_metric) { Fluent::Plugin::Prometheus::Counter.new(element, registry, {}, {}) }

    def instrument_other(path, value = 1)
      other_metric.instrument({'foo' => value, 'path' => path}, expander)
    end

    it 'wraps one and the same client metric' do
      expect(other_metric.instance_variable_get(:@counter))
        .to equal(metric.instance_variable_get(:@counter))
    end

    it 'counts the label sets of both sections against one limit' do
      instrument('/a')
      instrument_other('/b')

      # the metric is full, whichever section the next record goes through
      expect { instrument_other('/c') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
      expect { instrument('/d') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
      expect(client_counter.values.keys).to contain_exactly({path: '/a'}, {path: '/b'})
    end

    it 'lets both sections instrument a label set the metric already holds' do
      instrument('/a')

      expect { instrument_other('/a', 2) }.not_to raise_error
      expect(client_counter.values[{path: '/a'}]).to eq(3)
    end
  end

  describe 'initialized true with <initlabels>' do
    let(:initlabels) { ['/a', '/b', '/c'] }
    let(:element) do
      Fluent::Config::Element.new(
        'metric', '',
        {
          'name' => 'limited',
          'type' => 'counter',
          'desc' => 'Something foo.',
          'key' => 'foo',
          'initialized' => 'true',
          'max_series_per_metric' => max_series_per_metric.to_s,
        },
        [Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, [])] +
          initlabels.map { |path| Fluent::Config::Element.new('initlabels', '', {'path' => path}, []) }
      )
    end

    context 'with a limit below the number of <initlabels> label sets' do
      # 3 label sets exist at startup, so a limit of 1 would drop every record
      let(:max_series_per_metric) { 1 }

      it 'stops at startup instead of dropping every record' do
        expect { build_metrics(element) }
          .to raise_error(Fluent::ConfigError,
                          /already holds 3 label sets from <initlabels>.*max_series_per_metric is 1/)
      end
    end

    context 'with a limit equal to the number of <initlabels> label sets' do
      # every label set is known in advance, so the limit is reached but no
      # record is dropped
      let(:max_series_per_metric) { 3 }

      it 'accepts the config' do
        expect { build_metrics(element) }.not_to raise_error
      end

      it 'still counts a record on an <initlabels> label set' do
        instrument('/a')

        expect(client_counter.values[{path: '/a'}]).to eq(1)
      end

      it 'refuses a label set which is not in <initlabels>' do
        expect { instrument('/d') }.to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
      end
    end

    context 'with two <initlabels> holding the same values' do
      # both make the same label set, so they take one slot
      let(:initlabels) { ['/a', '/a'] }
      let(:max_series_per_metric) { 1 }

      it 'counts the label sets and not the <initlabels> blocks' do
        expect { build_metrics(element) }.not_to raise_error
      end
    end

    context 'without a limit' do
      let(:max_series_per_metric) { 0 }

      it 'accepts any number of <initlabels> label sets' do
        expect { build_metrics(element) }.not_to raise_error
        expect { instrument('/d') }.not_to raise_error
      end
    end
  end

  describe '<initlabels> shared by <metric> sections with the same name' do
    # Every section with this name instruments the same client metric. The
    # label sets from <initlabels> count in every section, even in one that
    # declares none. A section with no limit still adds its own to the count.
    let(:five_initlabels) { ['/a', '/b', '/c', '/d', '/e'] }

    it 'refuses a section that has no <initlabels>' do
      expect { build_metrics(counter_element(10, five_initlabels), counter_element(3)) }
        .to raise_error(Fluent::ConfigError,
                        /already holds 5 label sets from <initlabels>.*max_series_per_metric is 3/)
    end

    it 'counts the <initlabels> of a section that has no limit' do
      expect { build_metrics(counter_element(0, five_initlabels), counter_element(3, ['/z'])) }
        .to raise_error(Fluent::ConfigError,
                        /already holds 6 label sets from <initlabels>.*max_series_per_metric is 3/)
    end

    it 'does not depend on the order of the sections' do
      expect { build_metrics(counter_element(3), counter_element(10, five_initlabels)) }
        .to raise_error(Fluent::ConfigError, /max_series_per_metric is 3/)
    end

    it 'accepts a config when every limit fits the shared label sets' do
      expect { build_metrics(counter_element(5, five_initlabels), counter_element(10)) }
        .not_to raise_error
    end

    it 'counts them against the limit at runtime as well' do
      # the section with no limit puts them on the client, so the section with
      # a limit has to see them: none of its six slots is left
      _unlimited, limited = build_metrics(counter_element(0, five_initlabels),
                                          counter_element(6, ['/z']))

      expect { limited.instrument({'foo' => 1, 'path' => '/new'}, expander) }
        .to raise_error(Fluent::Plugin::Prometheus::LabelSetLimitError)
    end
  end

  describe 'reading the configuration again' do
    # A reload builds the <metric> sections again against the registry the
    # process already has, so the client metric keeps its label sets. Reading
    # the configuration twice here does the same.
    def instrument_through(metric, path)
      metric.instrument({'foo' => 1, 'path' => path}, expander)
    end

    it 'does not count the label sets that records brought' do
      # the section with the wider limit fills five slots of the set both
      # sections share, which leaves none for the limit of three
      wide, _narrow = build_metrics(counter_element(10), counter_element(3))
      ['/a', '/b', '/c', '/d', '/e'].each { |path| instrument_through(wide, path) }

      expect { build_metrics(counter_element(10), counter_element(3)) }.not_to raise_error
    end

    it 'accepts the same <initlabels> again' do
      metric, = build_metrics(counter_element(3, ['/a', '/b', '/c']))
      instrument_through(metric, '/a')

      expect { build_metrics(counter_element(3, ['/a', '/b', '/c'])) }.not_to raise_error
    end

    it 'keeps counting an <initlabels> label set a record came on' do
      # the client still holds the three label sets, so a limit of 2 does not
      # fit them even though a record made one of them look like its own
      metric, = build_metrics(counter_element(3, ['/a', '/b', '/c']))
      instrument_through(metric, '/a')

      expect { build_metrics(counter_element(2, ['/a', '/b', '/c'])) }
        .to raise_error(Fluent::ConfigError,
                        /already holds 3 label sets from <initlabels>.*max_series_per_metric is 2/)
    end
  end

  describe '<metric> overriding the plugin limit' do
    # the plugin is configured with 100, which <metric> has to win over
    let(:metric) do
      Fluent::Plugin::Prometheus::Counter.new(element, registry, {}, {max_series_per_metric: 100})
    end

    it 'narrows down the limit given to the plugin' do
      expect(metric.max_series_per_metric).to eq(1)
    end

    context 'with a limit above the one given to the plugin' do
      let(:max_series_per_metric) { 1000 }

      it 'widens the limit given to the plugin' do
        expect(metric.max_series_per_metric).to eq(1000)
      end
    end

    context 'with 0' do
      let(:max_series_per_metric) { 0 }

      it 'lifts the limit given to the plugin' do
        expect(metric.max_series_per_metric).to eq(0)
      end
    end

    context 'without a limit in <metric>' do
      let(:element) do
        Fluent::Config::Element.new(
          'metric', '',
          {
            'name' => 'limited',
            'type' => 'counter',
            'desc' => 'Something foo.',
            'key' => 'foo',
          },
          [Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, [])]
        )
      end

      it 'falls back to the limit given to the plugin' do
        expect(metric.max_series_per_metric).to eq(100)
      end
    end
  end
end
