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
  bind ::1
] }
      it 'should be configurable' do
        expect(driver.instance.bind).to eq('::1')
      end
    end

    describe 'default bind' do
      let(:config) { CONFIG }
      it 'should be accessible from 127.0.0.1 by default' do
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

    describe 'default ignore_error_log_interval' do
      let(:config) { CONFIG }
      it 'should be 3600 seconds by default' do
        expect(driver.instance.ignore_error_log_interval).to eq(3600)
      end
    end

    describe 'error_log_interval' do
      let(:config) { CONFIG + %[
    ignore_error_log_interval 60
] }
      it 'should be configurable' do
        expect(driver.instance.ignore_error_log_interval).to eq(60)
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

    context 'IPv6 with TLS' do
      let(:config) do
        %[
           @type prometheus
           bind ::1
           <transport tls>
             insecure true
           </transport>
         ]
      end

      it 'raises ConfigError for unsupported combination' do
        expect { driver.run(timeout: 1) }.to raise_error(Fluent::ConfigError, /IPv6 with <transport tls> is not currently supported/)
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

  describe '#run with IPv6' do
    shared_examples 'IPv6 server binding' do |bind_addr, connect_addr, description|
      let(:config) do
        # Quote the bind address if it contains brackets
        bind_value = bind_addr.include?('[') ? "\"#{bind_addr}\"" : bind_addr
        %[
          @type prometheus
          bind #{bind_value}
        ]
      end

      it description do
        skip 'IPv6 not available on this system' unless ipv6_enabled?

        driver.run(timeout: 3) do
          Net::HTTP.start(connect_addr, port) do |http|
            req = Net::HTTP::Get.new('/metrics')
            res = http.request(req)
            expect(res.code).to eq('200')
          end
        end
      end
    end

    context 'IPv6 loopback address ::1' do
      include_examples 'IPv6 server binding', '::1', '::1', 'binds and serves on IPv6 loopback address'
    end

    context 'IPv6 any address ::' do
      include_examples 'IPv6 server binding', '::', '::1', 'binds on :: and connects via ::1'
    end

    context 'pre-bracketed IPv6 address [::1]' do
      include_examples 'IPv6 server binding', '[::1]', '::1', 'handles pre-bracketed address correctly'
    end
  end

  describe 'error handling (information disclosure)' do
    let(:config) { LOCAL_CONFIG }
    let(:secret_message) { 'dummy secret detail: password=deadbeef' }

    shared_examples 'suppressed exception response' do
      it 'returns 500 with text/plain' do
        status, header, _body = subject
        expect(status).to eq(500)
        expect(header['Content-Type']).to eq('text/plain')
      end

      it 'exposes the exception class only' do
        _status, _header, body = subject
        expect(body).to eq('in_prometheus server error: <RuntimeError>')
        expect(body).not_to include(secret_message)
      end

      it 'logs the detail on the server side' do
        subject
        expect(driver.logs.any? { |log| log.include?(log_message) }).to be true
        expect(driver.logs.any? { |log| log.include?(secret_message) }).to be true
      end
    end

    context '#all_metrics' do
      subject { driver.instance.send(:all_metrics) }

      let(:log_message) { 'in_prometheus: failed to render metrics' }

      before do
        allow(::Prometheus::Client::Formats::Text).to receive(:marshal).and_raise(RuntimeError, secret_message)
      end

      include_examples 'suppressed exception response'
    end

    context '#all_workers_metrics' do
      subject { driver.instance.send(:all_workers_metrics) }

      let(:log_message) { 'in_prometheus: failed to render workers metrics' }

      before do
        allow(driver.instance).to receive(:send_request_to_each_worker).and_raise(RuntimeError, secret_message)
      end

      include_examples 'suppressed exception response'
    end

    context 'over HTTP' do
      before do
        allow(::Prometheus::Client::Formats::Text).to receive(:marshal).and_raise(RuntimeError, secret_message)
      end

      it 'does not leak the exception message to the client' do
        driver.run(timeout: 1) do
          Net::HTTP.start('127.0.0.1', port) do |http|
            req = Net::HTTP::Get.new('/metrics')
            res = http.request(req)
            expect(res.code).to eq('500')
            expect(res.body).to eq('in_prometheus server error: <RuntimeError>')
            expect(res.body).not_to include(secret_message)
          end
        end
      end
    end
  end

  # The LogThrottle spec covers the throttling itself. These examples cover how
  # in_prometheus uses it: the scope it throttles on, the fingerprint it makes
  # from an error, the suppressed_log_count in the log, and what the client
  # gets meanwhile.
  describe 'error log throttling' do
    let(:config) { LOCAL_CONFIG }
    let(:secret_message) { 'dummy secret detail: password=deadbeef' }
    let(:log_message) { 'in_prometheus: failed to render metrics' }
    let(:workers_log_message) { 'in_prometheus: failed to render workers metrics' }

    # Fluent::Clock.now is monotonic, so a plain Hash is enough to drive it
    let(:clock) { { now: 1000.0 } }

    def error_logs(message)
      driver.logs.select { |log| log.include?(message) }
    end

    context 'when rendering metrics keeps failing' do
      before do
        allow(Fluent::Clock).to receive(:now) { clock[:now] }
        allow(::Prometheus::Client::Formats::Text).to receive(:marshal).and_raise(RuntimeError, secret_message)
      end

      # every iteration raises from the same line, so the exceptions are equal
      # to each other and only ignore_error_log_interval can let a log through
      it 'logs the repeated same failure only once within ignore_error_log_interval' do
        5.times { driver.instance.send(:all_metrics) }
        expect(error_logs(log_message).size).to eq(1)
      end

      it 'keeps returning 500 to the client even while the log is suppressed' do
        responses = 5.times.map { driver.instance.send(:all_metrics) }
        expect(error_logs(log_message).size).to eq(1)
        responses.each do |status, _header, body|
          expect(status).to eq(500)
          expect(body).to eq('in_prometheus server error: <RuntimeError>')
        end
      end

      it 'reports how many logs were suppressed in the meantime' do
        3.times { driver.instance.send(:all_metrics) }
        clock[:now] += driver.instance.ignore_error_log_interval
        driver.instance.send(:all_metrics)
        logs = error_logs(log_message)
        expect(logs.size).to eq(2)
        expect(logs.first).not_to include('suppressed_log_count')
        expect(logs.last).to include('suppressed_log_count=2')
      end
    end

    describe 'telling the errors apart' do
      before do
        allow(Fluent::Clock).to receive(:now) { clock[:now] }
      end

      def log_error(scope, message, error)
        driver.instance.send(:log_error_throttled, scope, message, error: error)
      end

      # the class and the message both take part in the fingerprint
      it 'logs immediately when the error class differs' do
        log_error(:metrics, log_message, RuntimeError.new(secret_message))
        log_error(:metrics, log_message, ArgumentError.new(secret_message))
        expect(error_logs(log_message).size).to eq(2)
      end

      it 'logs immediately when the error differs' do
        log_error(:metrics, log_message, RuntimeError.new(secret_message))
        log_error(:metrics, log_message, RuntimeError.new('another failure'))
        expect(error_logs(log_message).size).to eq(2)
      end

      # the scope, not the log message, picks the slot to throttle on
      it 'suppresses an equal error within a scope even when the log message differs' do
        error = RuntimeError.new(secret_message)
        log_error(:metrics, log_message, error)
        log_error(:metrics, workers_log_message, error)
        expect(error_logs(workers_log_message)).to be_empty
      end

      # the only example which takes the interval from the configuration
      context 'with ignore_error_log_interval 0' do
        let(:config) { LOCAL_CONFIG + %[
  ignore_error_log_interval 0
] }

        it 'logs every occurrence of the same error' do
          3.times { log_error(:metrics, log_message, RuntimeError.new(secret_message)) }
          expect(error_logs(log_message).size).to eq(3)
        end
      end
    end

    # /metrics and /aggregated_metrics are usually scraped in turn, so both of
    # them must be throttled on their own slot
    context 'when both endpoints keep failing alternately' do
      before do
        allow(Fluent::Clock).to receive(:now) { clock[:now] }
        allow(::Prometheus::Client::Formats::Text).to receive(:marshal).and_raise(RuntimeError, secret_message)
        allow(driver.instance).to receive(:send_request_to_each_worker).and_raise(ArgumentError, 'another failure')
      end

      it 'logs each failure only once within ignore_error_log_interval' do
        5.times do
          driver.instance.send(:all_metrics)
          driver.instance.send(:all_workers_metrics)
        end
        expect(error_logs(log_message).size).to eq(1)
        expect(error_logs(workers_log_message).size).to eq(1)
      end
    end
  end
end
