require 'spec_helper'
require 'fluent/plugin/in_prometheus'
require 'fluent/test/driver/input'

require 'net/http'
require 'zlib'

describe Fluent::Plugin::PrometheusInput do
  CONFIG = %[
  @type prometheus
]

  LOCAL_CONFIG = %[
  @type prometheus
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

    describe 'content_encoding_identity' do
      let(:config) { CONFIG + %[
    content_encoding identity
] }
      it 'should be configurable' do
        expect(driver.instance.content_encoding).to eq(:identity)
      end
    end

    describe 'content_encoding_gzip' do
      let(:config) { CONFIG + %[
    content_encoding gzip
] }
      it 'should be configurable' do
        expect(driver.instance.content_encoding).to eq(:gzip)
      end
    end
  end

  describe '#start' do
    context 'with transport section' do
      let(:config) do
        %[
           @type prometheus
           bind 127.0.0.1
           <transport tls>
             insecure true
           </transport>
         ]
      end

      it 'returns 200' do
        driver.run(timeout: 1) do
          Net::HTTP.start('127.0.0.1', port, verify_mode: OpenSSL::SSL::VERIFY_NONE, use_ssl: true) do |http|
            req = Net::HTTP::Get.new('/metrics')
            res = http.request(req)
            expect(res.code).to eq('200')
          end
        end
      end
    end

    context 'old parameters are given' do
      context 'when extra_conf is used' do
        let(:config) do
          %[
            @type prometheus
            bind 127.0.0.1
            <ssl>
              enable true
              extra_conf { "SSLCertName": [["CN", "nobody"], ["DC", "example"]] }
            </ssl>
         ]
        end

        it 'uses webrick' do
          expect(driver.instance).to receive(:start_webrick).once
          driver.run(timeout: 1)
        end

        it 'returns 200' do
          driver.run(timeout: 1) do
            Net::HTTP.start('127.0.0.1', port, verify_mode: OpenSSL::SSL::VERIFY_NONE, use_ssl: true) do |http|
              req = Net::HTTP::Get.new('/metrics')
              res = http.request(req)
              expect(res.code).to eq('200')
            end
          end
        end
      end

      context 'cert_path and private_key_path combination' do
        let(:config) do
          %[
            @type prometheus
            bind 127.0.0.1
            <ssl>
              enable true
              certificate_path path
              private_key_path path1
            </ssl>
          ]
        end

        it 'converts them into new transport section' do
          expect(driver.instance).to receive(:http_server_create_http_server).with(
                                       :in_prometheus_server,
                                       addr: anything,
                                       logger: anything,
                                       port: anything,
                                       proto: :tls,
                                       tls_opts: { 'cert_path' => 'path', 'private_key_path' => 'path1' }
                                     ).once

          driver.run(timeout: 1)
        end
      end

      context 'insecure and ca_path' do
        let(:config) do
          %[
            @type prometheus
            bind 127.0.0.1
            <ssl>
              enable true
              ca_path path
            </ssl>
           ]
        end

        it 'converts them into new transport section' do
          expect(driver.instance).to receive(:http_server_create_http_server).with(
                                       :in_prometheus_server,
                                       addr: anything,
                                       logger: anything,
                                       port: anything,
                                       proto: :tls,
                                       tls_opts: { 'ca_path' => 'path', 'insecure' => true }
                                     ).once

          driver.run(timeout: 1)
        end
      end

      context 'when only private_key_path is geven' do
        let(:config) do
          %[
            @type prometheus
            bind 127.0.0.1
            <ssl>
              enable true
              private_key_path path
            </ssl>
           ]
        end

        it 'raises ConfigError' do
          expect { driver.run(timeout: 1) }.to raise_error(Fluent::ConfigError, 'both certificate_path and private_key_path must be defined')
        end
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

    context 'response content_encoding identity' do
      let(:config) { LOCAL_CONFIG + %[
        content_encoding identity
  ] }
      it 'exposes metric' do
        driver.run(timeout: 1) do
          registry = driver.instance.instance_variable_get(:@registry)
          registry.counter(:test,docstring: "Testing metrics") unless registry.exist?(:test)
          Net::HTTP.start("127.0.0.1", port) do |http|
            req = Net::HTTP::Get.new("/metrics")
            req['accept-encoding'] = nil
            res = http.request(req)
            expect(res.body).to include("test Testing metrics")
          end
        end
      end
    end

    context 'response content_encoding gzip' do
      let(:config) { LOCAL_CONFIG + %[
        content_encoding gzip
  ] }
      it 'exposes metric' do
        driver.run(timeout: 1) do
          registry = driver.instance.instance_variable_get(:@registry)
          registry.counter(:test,docstring: "Testing metrics") unless registry.exist?(:test)
          Net::HTTP.start("127.0.0.1", port) do |http|
            req = Net::HTTP::Get.new("/metrics")
            req['accept-encoding'] = nil
            res = http.request(req)
            gzip = Zlib::GzipReader.new(StringIO.new(res.body.to_s))
            expect(gzip.read).to include("test Testing metrics")
          end
        end
      end
    end
  end

  describe '#run_multi_workers' do
    context '/metrics' do
      Fluent::SystemConfig.overwrite_system_config('workers' => 4) do
        let(:config) { FULL_CONFIG + %[
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
