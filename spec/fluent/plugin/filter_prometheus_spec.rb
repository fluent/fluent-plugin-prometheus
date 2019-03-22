require 'spec_helper'
require 'fluent/test/driver/filter'
require 'fluent/plugin/filter_prometheus'
require_relative 'shared'

describe Fluent::Plugin::PrometheusFilter do
  let(:tag) { 'prometheus.test' }
  let(:driver) { Fluent::Test::Driver::Filter.new(Fluent::Plugin::PrometheusFilter).configure(config) }
  let(:registry) { ::Prometheus::Client.registry }

  describe '#configure' do
    it_behaves_like 'output configuration'
  end

  describe '#run' do
    let(:message) { {"foo" => 100, "bar" => 100, "baz" => 100, "qux" => 10} }
    let(:es) {
      driver.run(default_tag: tag) { driver.feed(event_time, message) }
      driver.filtered_records
    }

    context 'simple config' do
      include_context 'simple_config'

      it 'adds a new counter metric' do
        expect(registry.metrics.map(&:name)).not_to include(name)
        es
        expect(registry.metrics.map(&:name)).to include(name)
      end

      it 'should keep original message' do
        expect(es.first).to eq(message)
      end
    end

    it_behaves_like 'instruments record'
  end
end
