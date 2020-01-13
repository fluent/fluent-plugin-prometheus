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
    end

    it_behaves_like 'instruments record'
  end
end
