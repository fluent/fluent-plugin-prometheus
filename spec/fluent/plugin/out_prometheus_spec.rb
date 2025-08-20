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

  describe '#testinitlabels' do
    it_behaves_like 'initalized metrics'
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

  describe '#run with symbolized keys' do
    let(:message) { {:foo => 100, :bar => 100, :baz => 100, :qux => 10} }

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

  describe '#run with retention' do
    let(:message) { { "foo" => 100, "bar" => 100, "baz" => 100, "qux" => 10 } }
    let(:labels) { { :bar => 100, :baz => 100, :qux => 10 } }

    context 'config with retention 1' do
      let(:config) {
        BASE_CONFIG + %(
          <metric>
            name simple
            type counter
            desc Something foo.
            key foo
            <labels>
              bar ${bar}
              baz ${baz}
              qux ${qux}
            </labels>
            retention 1
            retention_check_interval 1
          </metric>
        )
      }

      it 'expires metric after max 2s' do
        expect(registry.metrics.map(&:name)).not_to eq([:simple])
        driver.run(default_tag: tag) {
          driver.feed(event_time, message)
          expect(registry.metrics[0].get(labels: labels)).to eq(100)
          sleep(2)
          expect(registry.metrics[0].get(labels: labels)).to eq(0.0)
        }
      end
    end
  end
end
