require 'spec_helper'
require 'fluent/plugin/filter_prometheus'
require_relative 'shared'

describe Fluent::PrometheusFilter do
  let(:tag) { 'prometheus.test' }
  let(:driver) { Fluent::Test::FilterTestDriver.new(Fluent::PrometheusFilter, tag).configure(config, true) }
  let(:registry) { ::Prometheus::Client.registry }

  describe '#configure' do
    it_behaves_like 'output configuration'
  end

  describe '#run' do
    let(:message) { {"foo" => 100, "bar" => 100, "baz" => 100} }
    let(:es) { driver.run { driver.emit(message, Time.now) }.filtered }

    context 'simple config' do
      let(:config) { SIMPLE_CONFIG.gsub('simple_foo', name.to_s) }
      let(:name) { "simple_foo_#{Time.now.to_f}".to_sym }

      it 'adds a new counter metric' do
        expect(registry.metrics.map(&:name)).not_to include(name)
        es
        expect(registry.metrics.map(&:name)).to include(name)
      end

      it 'should keep original message' do
        expect(es.first[1]).to eq(message)
      end
    end

    context 'full config' do
      let(:config) { FULL_CONFIG }
      let(:counter) { registry.get(:full_foo) }
      let(:gauge) { registry.get(:full_bar) }
      let(:summary) { registry.get(:full_baz) }

      before :each do
        es
      end

      it 'adds all metrics' do
        expect(registry.metrics.map(&:name)).to include(:full_foo)
        expect(registry.metrics.map(&:name)).to include(:full_bar)
        expect(registry.metrics.map(&:name)).to include(:full_baz)
        expect(counter).to be_kind_of(::Prometheus::Client::Metric)
        expect(gauge).to be_kind_of(::Prometheus::Client::Metric)
        expect(summary).to be_kind_of(::Prometheus::Client::Metric)
      end

      it 'instruments counter metric' do
        expect(counter.type).to eq(:counter)
        expect(counter.get({test_key: 'test_value', key: 'foo1'})).to be_kind_of(Integer)
      end

      it 'instruments gauge metric' do
        expect(gauge.type).to eq(:gauge)
        expect(gauge.get({test_key: 'test_value', key: 'foo2'})).to eq(100)
      end

      it 'instruments summary metric' do
        expect(summary.type).to eq(:summary)
        expect(summary.get({test_key: 'test_value', key: 'foo3'})).to be_kind_of(Hash)
        expect(summary.get({test_key: 'test_value', key: 'foo3'})[0.99]).to eq(100)
      end
    end
  end
end if defined?(Fluent::PrometheusFilter)
