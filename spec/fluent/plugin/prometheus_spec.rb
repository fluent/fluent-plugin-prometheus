require 'spec_helper'
require 'fluent/plugin/in_prometheus'

require 'net/http'

describe Fluent::PrometheusInput do
  CONFIG = %[
  type prometheus
]

  LOCAL_CONFIG = %[
  type prometheus
  bind 127.0.0.1
]

  let(:config) { CONFIG }
  let(:port) { 24231 }
  let(:driver) { Fluent::Test::InputTestDriver.new(Fluent::PrometheusInput).configure(config) }

  describe '#configure' do
    describe 'bind' do
      let(:config) { CONFIG + %[
  bind 127.0.0.1
] }
      it 'should be configurable' do
        expect(driver.instance.bind).to eq('127.0.0.1')
      end
    end

    describe 'port' do
      let(:config) { CONFIG + %[
  port 8888
] }
      it 'should be configurable' do
        expect(driver.instance.port).to eq(8888)
      end
    end

    describe 'metrics_path' do
      let(:config) { CONFIG + %[
  metrics_path /_test
] }
      it 'should be configurable' do
        expect(driver.instance.metrics_path).to eq('/_test')
      end
    end
  end

  describe '#run' do
    context '/metrics' do
      let(:config) { LOCAL_CONFIG }
      it 'returns 200' do
        driver.run do
          Net::HTTP.start("127.0.0.1", port) do |http|
            req = Net::HTTP::Get.new("/metrics")
            res = http.request(req)
            expect(res.code).to eq('200')
          end
        end
      end
    end

    context '/foo' do
      let(:config) { LOCAL_CONFIG }
      it 'does not return 200' do
        driver.run do
          Net::HTTP.start("127.0.0.1", port) do |http|
            req = Net::HTTP::Get.new("/foo")
            res = http.request(req)
            expect(res.code).not_to eq('200')
          end
        end
      end
    end
  end
end
