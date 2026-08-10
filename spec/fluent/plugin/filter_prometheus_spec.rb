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

  describe 'limiting label expansion' do
    it_behaves_like 'limits label expansion'
  end

  # the throttling itself is covered by the LogThrottle spec; what is left here
  # is the warning warn_label_set_limit builds out of it
  describe 'label set limit log throttling' do
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

    before do
      allow(Fluent::Clock).to receive(:now) { clock[:now] }
    end

    def drop_logs
      driver.logs.select { |log| log.include?('dropped a label set') }
    end

    it 'warns only once within ignore_error_log_interval' do
      5.times { driver.instance.send(:warn_label_set_limit, metric) }
      expect(drop_logs.size).to eq(1)
    end

    it 'reports how many warnings were suppressed in the meantime' do
      3.times { driver.instance.send(:warn_label_set_limit, metric) }
      clock[:now] += driver.instance.ignore_error_log_interval
      driver.instance.send(:warn_label_set_limit, metric)
      logs = drop_logs
      expect(logs.size).to eq(2)
      expect(logs.first).not_to include('suppressed_log_count')
      expect(logs.last).to include('suppressed_log_count=2')
    end
  end
end
