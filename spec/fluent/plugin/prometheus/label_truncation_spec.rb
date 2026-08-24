require 'spec_helper'

# The truncation is exercised through the plugins as well, by the 'limits label
# expansion' shared examples. These examples stay at the Metric level, where the
# callback given to a metric can be observed directly.
describe Fluent::Plugin::Prometheus::Metric do
  let(:registry) { ::Prometheus::Client::Registry.new }
  let(:max_label_value_length) { 4 }
  let(:truncations) { [] }
  let(:opts) do
    { on_label_value_truncated: ->(metric, key) { truncations << [metric.name, key] } }
  end
  let(:element) do
    Fluent::Config::Element.new(
      'metric', '',
      {
        'name' => 'truncated',
        'type' => 'counter',
        'desc' => 'Something foo.',
        'key' => 'foo',
        'max_label_value_length' => max_label_value_length.to_s,
      },
      [Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, [])]
    )
  end
  # the label is a RecordAccessor, so no placeholder is expanded here
  let(:expander) { double('expander') }
  let(:metric) { Fluent::Plugin::Prometheus::Counter.new(element, registry, {}, opts) }
  # the client metric is registered by the Metric, so it has to be built before
  # the registry is asked for it
  let(:client_counter) do
    metric
    registry.get(:truncated)
  end

  def instrument(path)
    metric.instrument({'foo' => 1, 'path' => path}, expander)
  end

  describe 'max_label_value_length' do
    it 'reports which label it truncated' do
      instrument('/abcdefg')

      expect(truncations).to eq([['truncated', :path]])
    end

    # two records, one series: this is what the report makes countable
    it 'reports every truncation, not only the first one' do
      instrument('/abcdefg')
      instrument('/abcxyz')

      expect(truncations.size).to eq(2)
      expect(client_counter.values.keys).to eq([{path: '/abc'}])
    end

    it 'reports nothing when the label value fits in the limit' do
      instrument('/ab')

      expect(truncations).to be_empty
    end

    it 'reports nothing when the label value is exactly as long as the limit' do
      instrument('/abc')

      expect(truncations).to be_empty
      expect(client_counter.values.keys).to eq([{path: '/abc'}])
    end

    context 'with 0' do
      let(:max_label_value_length) { 0 }

      it 'reports nothing, since nothing is truncated' do
        instrument('/abcdefg')

        expect(truncations).to be_empty
        expect(client_counter.values.keys).to eq([{path: '/abcdefg'}])
      end
    end
  end

  # They are given to the client as is, so they have to be truncated like the
  # label sets built from records. They come from the configuration though, so
  # the truncation is not reported: nothing an operator can act on is merged.
  describe 'the pre-initialized label sets' do
    let(:element) do
      Fluent::Config::Element.new(
        'metric', '',
        {
          'name' => 'truncated',
          'type' => 'counter',
          'desc' => 'Something foo.',
          'key' => 'foo',
          'initialized' => 'true',
          'max_label_value_length' => max_label_value_length.to_s,
        },
        [
          Fluent::Config::Element.new('labels', '', {'path' => '$.path'}, []),
          Fluent::Config::Element.new('initlabels', '', {'path' => '/abcdefg'}, []),
        ]
      )
    end

    it 'are given to the client truncated' do
      expect(client_counter.values.keys).to eq([{path: '/abc'}])
    end

    # otherwise the client would hold both '/abcdefg' and '/abc', and the
    # metric would grow past max_series_per_metric
    it 'take the same series as a record which expands to them' do
      instrument('/abcdefg')

      expect(client_counter.values).to eq({{path: '/abc'} => 1.0})
    end

    it 'are not reported as a truncation' do
      metric

      expect(truncations).to be_empty
    end
  end
end
