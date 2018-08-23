require 'fluent/plugin/input'
require 'fluent/plugin/prometheus'
require 'webrick'

module Fluent::Plugin
  class PrometheusInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('prometheus', self)

    helpers :thread

    config_param :bind, :string, default: '0.0.0.0'
    config_param :port, :integer, default: 24231
    config_param :metrics_path, :string, default: '/metrics'

    desc 'Enable ssl configuration for the server'
    config_section :ssl, required: false, multi: false do
      config_param :enable, :bool, default: false

      desc 'Path to the ssl certificate in PEM format.  Read from file and added to conf as "SSLCertificate"'
      config_param :certificate_path, :string, default: nil

      desc 'Path to the ssl private key in PEM format.  Read from file and added to conf as "SSLPrivateKey"'
      config_param :private_key_path, :string, default: nil

      desc 'Path to CA in PEM format.  Read from file and added to conf as "SSLCACertificateFile"'
      config_param :ca_path, :string, default: nil

      desc 'Additional ssl conf for the server.  Ref: https://github.com/ruby/webrick/blob/master/lib/webrick/ssl.rb'
      config_param :extra_conf, :hash, default: {:SSLCertName => [['CN','nobody'],['DC','example']]}, symbolize_keys: true
    end

    attr_reader :registry

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      @port += fluentd_worker_id
    end

    def multi_workers_ready?
      true
    end

    def start
      super
      log.debug "listening prometheus http server on http://#{@bind}:#{@port}/#{@metrics_path} for worker#{fluentd_worker_id}"
      config = {
        BindAddress: @bind,
        Port: @port,
        MaxClients: 5,
        Logger: WEBrick::Log.new(STDERR, WEBrick::Log::FATAL),
        AccessLog: [],
      }
      unless @ssl.nil? || !@ssl['enable']
        require 'webrick/https'
        require 'openssl'
        if (@ssl['certificate_path'] && @ssl['private_key_path'].nil?) || (@ssl['certificate_path'].nil? && @ssl['private_key_path'])
            raise RuntimeError.new("certificate_path and private_key_path most both be defined")
        end
        ssl_config = {
            SSLEnable: true
        }
        if @ssl['certificate_path']
          cert = OpenSSL::X509::Certificate.new(File.read(@ssl['certificate_path']))
          ssl_config[:SSLCertificate] = cert
        end
        if @ssl['private_key_path']
          key = OpenSSL::PKey::RSA.new(File.read(@ssl['private_key_path']))
          ssl_config[:SSLPrivateKey] = key
        end
        ssl_config[:SSLCACertificateFile] = @ssl['ca_path'] if @ssl['ca_path']
        ssl_config = ssl_config.merge(@ssl['extra_conf'])
        config = ssl_config.merge(config)
      end
      @log.on_debug do
        @log.debug("WEBrick conf: #{config}")
      end

      @server = WEBrick::HTTPServer.new(config)
      @server.mount(@metrics_path, MonitorServlet, self)
      thread_create(:in_prometheus) do
        @server.start
      end
    end

    def shutdown
      if @server
        @server.shutdown
        @server = nil
      end
      super
    end

    class MonitorServlet < WEBrick::HTTPServlet::AbstractServlet
      def initialize(server, prometheus)
        @prometheus = prometheus
      end

      def do_GET(req, res)
        res.status = 200
        res['Content-Type'] = ::Prometheus::Client::Formats::Text::CONTENT_TYPE
        res.body = ::Prometheus::Client::Formats::Text.marshal(@prometheus.registry)
      rescue
        res.status = 500
        res['Content-Type'] = 'text/plain'
        res.body = $!.to_s
      end
    end
  end
end
