require 'fluent/input'
require 'fluent/plugin/prometheus'
require 'webrick'

module Fluent
  class PrometheusInput < Input
    Plugin.register_input('prometheus', self)

    config_param :bind, :string, :default => '0.0.0.0'
    config_param :port, :integer, :default => 24231
    config_param :metrics_path, :string, :default => '/metrics'

    attr_reader :registry

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
    end

    def start
      super
      @server = WEBrick::HTTPServer.new(
        BindAddress: @bind,
        Port: @port,
        Logger: WEBrick::Log.new(STDERR, WEBrick::Log::FATAL),
        AccessLog: [],
      )
      @server.mount(@metrics_path, MonitorServlet, self)
      @thread = Thread.new { @server.start }
    end

    def shutdown
      super
      if @server
        @server.shutdown
        @server = nil
      end
      if @thread
        @thread.join
        @thread = nil
      end
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
