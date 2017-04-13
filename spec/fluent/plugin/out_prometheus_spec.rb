require 'spec_helper'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_prometheus'
require_relative 'shared'

describe Fluent::Plugin::PrometheusOutput do
  let(:tag) { 'prometheus.test' }
  let(:driver) { Fluent::Test::Driver::Output.new(Fluent::Plugin::PrometheusOutput).configure(config) }
  let(:registry) { ::Prometheus::Client.registry }

  describe '#configure' do
    it_behaves_like 'output configuration'
  end

  describe '#run' do
    let(:message) { {"foo" => 100, "bar" => 100, "baz" => 100, "qux" => 10} }
    let(:es) {
      driver.run(default_tag: tag) { driver.feed(event_time, message) }
      driver.events
    }

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
