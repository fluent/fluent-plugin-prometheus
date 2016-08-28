require 'spec_helper'
require 'fluent/plugin/out_prometheus'
require_relative 'shared'

describe Fluent::PrometheusOutput do
  let(:tag) { 'prometheus.test' }
  let(:driver) { Fluent::Test::OutputTestDriver.new(Fluent::PrometheusOutput, tag).configure(config) }
  let(:registry) { ::Prometheus::Client.registry }

  describe '#configure' do
    it_behaves_like 'output configuration'
  end

  describe '#run' do
    let(:message) { {"foo" => 100, "bar" => 100, "baz" => 100, "qux" => 10} }
    let(:es) { driver.run { driver.emit(message, Time.now) } }

    context 'simple config' do
      include_context 'simple_config'

      it 'adds a new counter metric' do
        expect(registry.metrics.map(&:name)).not_to include(name)
        es
        expect(registry.metrics.map(&:name)).to include(name)
      end
    end

    it_behaves_like 'instruments record'
  end
end
