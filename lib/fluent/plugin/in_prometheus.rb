require 'fluent/plugin/input'
require 'fluent/plugin/prometheus'
require 'fluent/plugin/prometheus_metrics'
require 'net/http'
require 'webrick'

module Fluent::Plugin
  class PrometheusInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('prometheus', self)

    helpers :thread, :http_server

    config_param :bind, :string, default: '0.0.0.0'
    config_param :port, :integer, default: 24231
    config_param :metrics_path, :string, default: '/metrics'
    config_param :aggregated_metrics_path, :string, default: '/aggregated_metrics'

    desc 'Enable ssl configuration for the server'
    config_section :ssl, required: false, multi: false do
      config_param :enable, :bool, default: false, deprecated: 'Use <transport tls> section'

      desc 'Path to the ssl certificate in PEM format.  Read from file and added to conf as "SSLCertificate"'
      config_param :certificate_path, :string, default: nil, deprecated: 'Use cert_path in <transport tls> section'

      desc 'Path to the ssl private key in PEM format.  Read from file and added to conf as "SSLPrivateKey"'
      config_param :private_key_path, :string, default: nil, deprecated: 'Use private_key_path in <transport tls> section'

      desc 'Path to CA in PEM format.  Read from file and added to conf as "SSLCACertificateFile"'
      config_param :ca_path, :string, default: nil, deprecated: 'Use ca_path in <transport tls> section'

      desc 'Additional ssl conf for the server.  Ref: https://github.com/ruby/webrick/blob/master/lib/webrick/ssl.rb'
      config_param :extra_conf, :hash, default: nil, symbolize_keys: true, deprecated: 'See http helper config'
    end

    def initialize
      super
      @registry = ::Prometheus::Client.registry
      @secure = nil
    end

    def configure(conf)
      super

      # Get how many workers we have
      sysconf = if self.respond_to?(:owner) && owner.respond_to?(:system_config)
                  owner.system_config
                elsif self.respond_to?(:system_config)
                  self.system_config
                else
                  nil
                end
      @num_workers = sysconf && sysconf.workers ? sysconf.workers : 1
      @secure = @transport_config.protocol == :tls || (@ssl && @ssl['enable'])
      require 'openssl' if @secure

      @base_port = @port
      @port += fluentd_worker_id
    end

    def multi_workers_ready?
      true
    end

    def start
      super

      scheme = @secure ? 'https' : 'http'
      log.debug "listening prometheus http server on #{scheme}:://#{@bind}:#{@port}/#{@metrics_path} for worker#{fluentd_worker_id}"

      proto = @secure ? :tls : :tcp
      tls_opt = if @ssl && @ssl['enable']
                  ssl_config = {}

                  if (@ssl['certificate_path'] && @ssl['private_key_path'].nil?) || (@ssl['certificate_path'].nil? && @ssl['private_key_path'])
                    raise Fluent::ConfigError.new('both certificate_path and private_key_path must be defined')
                  end

                  if @ssl['certificate_path']
                    ssl_config['cert_path'] = @ssl['certificate_path']
                  end

                  if @ssl['private_key_path']
                    ssl_config['private_key_path'] = @ssl['private_key_path']
                  end

                  if @ssl['ca_path']
                    ssl_config['ca_path'] = @ssl['ca_path']
                    # Only ca_path is insecure in fluentd
                    # https://github.com/fluent/fluentd/blob/2236ad45197ba336fd9faf56f442252c8b226f25/lib/fluent/plugin_helper/cert_option.rb#L68
                    ssl_config['insecure'] = true
                  end

                  if @ssl['extra_conf']
                    raise Fluent::ConfigError.new("extra_conf is no longer supported. use transport section")
                  end

                  ssl_config
                end

      http_server_create_http_server(:in_prometheus_server, addr: @bind, port: @port, logger: log, proto: proto, tls_opts: tls_opt) do |server|
        server.get(@metrics_path) { |_req| all_metrics }
        server.get(@aggregated_metrics_path) { |_req| all_workers_metrics }
      end
    end

    private

    def all_metrics
      [200, { 'Content-Type' => ::Prometheus::Client::Formats::Text::CONTENT_TYPE }, ::Prometheus::Client::Formats::Text.marshal(@registry)]
    rescue => e
      [500, { 'Content-Type' => 'text/plain' }, e.to_s]
    end

    def all_workers_metrics
      full_result = PromMetricsAggregator.new

      send_request_to_each_worker do |resp|
        if resp.is_a?(Net::HTTPSuccess)
          full_result.add_metrics(resp.body)
        end
      end

      [200, { 'Content-Type' => ::Prometheus::Client::Formats::Text::CONTENT_TYPE }, full_result.get_metrics]
    rescue => e
      [500, { 'Content-Type' => 'text/plain' }, e.to_s]
    end

    def send_request_to_each_worker
      bind = (@bind == '0.0.0.0') ? '127.0.0.1' : @bind
      req = Net::HTTP::Get.new(@metrics_path)
      [*(@base_port...(@base_port + @num_workers))].each do |worker_port|
        do_request(host: bind, port: worker_port, secure: @secure) do |http|
          yield(http.request(req))
        end
      end
    end

    def do_request(host:, port:, secure:)
      http = Net::HTTP.new(host, port)

      if secure
        http.use_ssl = true
        # target is our child process. so it's secure.
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      http.start do
        yield(http)
      end
    end
  end
end
