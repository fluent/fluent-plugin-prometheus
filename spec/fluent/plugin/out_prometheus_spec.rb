require 'spec_helper'
require 'fluent/test/driver/output'
require 'fluent/plugin/out_prometheus'
require_relative 'shared'

describe Fluent::Plugin::PrometheusOutput do
  let(:tag) { 'prometheus.test' }
  let(:driver) { Fluent::Test::Driver::Output.new(Fluent::Plugin::PrometheusOutput).configure(config) }
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
      let(:name) { :simple_foo }
      let(:config) { SIMPLE_CONFIG }

      it 'adds a new counter metric' do
        expect(registry.metrics.map(&:name)).not_to include(name)
        driver.run(default_tag: tag) { driver.feed(event_time, message) }
        expect(registry.metrics.map(&:name)).to include(name)
      end
    end

    it_behaves_like 'instruments record'
  end
end
