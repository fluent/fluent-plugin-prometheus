require 'spec_helper'
require 'fluent/plugin/in_prometheus'
require 'fluent/test/driver/input'

require 'net/http'

describe Fluent::Plugin::PrometheusInput do
  CONFIG = %[
  type prometheus
]

  LOCAL_CONFIG = %[
  type prometheus
  bind 127.0.0.1
]

  let(:config) { CONFIG }
  let(:port) { 24231 }
  let(:driver) { Fluent::Test::Driver::Input.new(Fluent::Plugin::PrometheusInput).configure(config) }

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
        driver.run(timeout: 1) do
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
        driver.run(timeout: 1) do
          Net::HTTP.start("127.0.0.1", port) do |http|
            req = Net::HTTP::Get.new("/foo")
            res = http.request(req)
            expect(res.code).not_to eq('200')
          end
        end
      end
    end
  end

  describe '#run_multi_workers' do
    context '/metrics' do
      Fluent::SystemConfig.overwrite_system_config('workers' => 4) do
        let(:config) { CONFIG + %[
          port #{port - 2}
        ] }

        it 'should configure port using sequential number' do
          driver = Fluent::Test::Driver::Input.new(Fluent::Plugin::PrometheusInput)
          driver.instance.instance_eval{ @_fluentd_worker_id = 2 }
          driver.configure(config)
          expect(driver.instance.port).to eq(port)
          driver.run(timeout: 1) do
            Net::HTTP.start("127.0.0.1", port) do |http|
              req = Net::HTTP::Get.new("/metrics")
              res = http.request(req)
              expect(res.code).to eq('200')
            end
          end
        end
      end
    end
  end
end
