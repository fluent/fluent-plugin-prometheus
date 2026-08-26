require 'spec_helper'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_prometheus'
require_relative 'shared'

describe Fluent::Plugin::PrometheusFilter do
  let(:tag) { 'prometheus.test' }
  let(:driver) { Fluent::Test::Driver::Filter.new(Fluent::Plugin::PrometheusFilter).configure(config) }
  let(:registry) { ::Prometheus::Client::Registry.new }

  before do
    allow(Prometheus::Client).to receive(:registry).and_return(registry)
  end

  describe '#configure' do
    it_behaves_like 'output configuration'
  end

  describe '#run' do
    let(:message) { {"foo" => 100, "bar" => 100, "baz" => 100, "qux" => 10} }

    context 'simple config' do
      let(:config) {
        BASE_CONFIG + %(
          <metric>
            name simple
            type counter
            desc Something foo.
            key foo
          </metric>
        )
      }

      it 'adds a new counter metric' do
        expect(registry.metrics.map(&:name)).not_to eq([:simple])
        driver.run(default_tag: tag) { driver.feed(event_time, message) }
        expect(registry.metrics.map(&:name)).to eq([:simple])
      end

      it 'should keep original message' do
        driver.run(default_tag: tag) { driver.feed(event_time, message) }
        expect(driver.filtered_records.first).to eq(message)
      end
    end

    it_behaves_like 'instruments record'
  end

  # a label which uses the tag must be expanded with the tag, not with the
  # record.
  describe 'a record which has a tag placeholder name' do
    let(:config) {
      BASE_CONFIG + %(
        <metric>
          name tagged
          type counter
          desc Something foo.
          key foo
          <labels>
            part ${tag_parts[0]}
          </labels>
        </metric>
      )
    }

    it 'labels the metric with the tag' do
      driver.run(default_tag: tag) do
        driver.feed(event_time, {'tag' => 'forged.tag', 'foo' => 1, 'tag_parts' => ['forged']})
      end
      # even though tag_parts exists in the record, it should not be taken as "part".
      expect(registry.get(:tagged).values.keys).to eq([{part: 'prometheus'}])
    end

    it 'labels the metric with the tag, not with the record key' do
      driver.run(default_tag: tag) do
        driver.feed(event_time, {'tag' => 'forged.tag', 'foo' => 1, 'tag_parts[0]' => 'forged'})
      end
      # the record has a key named "tag_parts[0]", but the tag must win.
      expect(registry.get(:tagged).values.keys).to eq([{part: 'prometheus'}])
    end
  end

  # a record must not fill an index which the tag does not have.
  describe 'a record which uses an index out of the tag' do
    let(:config) {
      BASE_CONFIG + %(
        <metric>
          name out_of_range
          type counter
          desc Something foo.
          key foo
          <labels>
            part ${tag_parts[2]}
            prefix ${tag_prefix[-1]}
            suffix ${tag_suffix[-1]}
          </labels>
        </metric>
      )
    }

    it 'leaves the label unexpanded' do
      driver.run(default_tag: tag) do
        driver.feed(event_time, {
                      'foo' => 1,
                      'tag_parts[2]' => 'forged',
                      'tag_prefix[-1]' => 'forged',
                      'tag_suffix[-1]' => 'forged',
                    })
      end
      # the tag "prometheus.test" has 2 parts, and tag_prefix and tag_suffix
      # have no negative index. So these labels must not be expanded.
      expect(registry.get(:out_of_range).values.keys).to eq(
        [{part: '${tag_parts[2]}', prefix: '${tag_prefix[-1]}', suffix: '${tag_suffix[-1]}'}]
      )
    end
  end

  describe 'limiting label expansion' do
    it_behaves_like 'limits label expansion'
  end

  # the throttling itself is covered by the LogThrottle spec; what is left here
  # is the warning warn_label_set_limit builds out of it, and the interval it
  # takes from the configuration
  describe 'drop log throttling' do
    let(:config) {
      BASE_CONFIG + %[
        ignore_error_log_interval 3600
        <metric>
          name throttled
          type counter
          desc Something foo.
          key foo
        </metric>
      ]
    }
    # Fluent::Clock.now is monotonic, so a plain Hash is enough to drive it
    let(:clock) { { now: 1000.0 } }
    let(:metric) { double('metric', name: :throttled, max_series_per_metric: 5) }
    let(:text) { 'dropped a label set' }

    before do
      allow(Fluent::Clock).to receive(:now) { clock[:now] }
    end

    def logs_about(text)
      driver.logs.select { |log| log.include?(text) }
    end

    def drop
      driver.instance.send(:warn_label_set_limit, metric)
    end

    it 'warns only once within ignore_error_log_interval' do
      5.times { drop }
      expect(logs_about(text).size).to eq(1)
    end

    it 'reports how many warnings were suppressed in the meantime' do
      3.times { drop }
      clock[:now] += driver.instance.ignore_error_log_interval
      drop
      logs = logs_about(text)
      expect(logs.size).to eq(2)
      expect(logs.first).not_to include('suppressed_log_count')
      expect(logs.last).to include('suppressed_log_count=2')
    end

    # the only example which takes the interval from the configuration
    context 'with ignore_error_log_interval 0' do
      let(:config) {
        BASE_CONFIG + %[
          ignore_error_log_interval 0
          <metric>
            name throttled
            type counter
            desc Something foo.
            key foo
          </metric>
        ]
      }

      it 'warns about every drop' do
        3.times { drop }
        expect(logs_about(text).size).to eq(3)
      end
    end
  end
end
