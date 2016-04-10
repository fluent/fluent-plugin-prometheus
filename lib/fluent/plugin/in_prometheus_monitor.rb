require 'fluent/plugin/prometheus'
require 'webrick'

module Fluent
  class PrometheusMonitorInput < Input
    Plugin.register_input('prometheus_monitor', self)

    config_param :interval, :time, :default => 5
    attr_reader :registry

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      hostname = Socket.gethostname
      expander = Fluent::Prometheus.placeholder_expnader(log)
      placeholders = expander.prepare_placeholders({'hostname' => hostname})
      @base_labels = Fluent::Prometheus.parse_labels_elements(conf)
      @base_labels.each do |key, value|
        @base_labels[key] = expander.expand(value, placeholders)
      end

      @monitor_agent = MonitorAgentInput.new

      buffer_queue_length = @registry.gauge(
        :fluentd_status_buffer_queue_length,
        'Current buffer queue length.')
      buffer_total_queued_size = @registry.gauge(
        :fluentd_status_buffer_total_bytes,
        'Current total size of ququed buffers.')
      retry_counts = @registry.gauge(
        :fluentd_status_retry_count,
        'Current retry counts.')

      @monitor_info = {
        'buffer_queue_length' => buffer_queue_length,
        'buffer_total_queued_size' => buffer_total_queued_size,
        'retry_count' => retry_counts,
      }
    end

    class TimerWatcher < Coolio::TimerWatcher
      def initialize(interval, repeat, log, &callback)
        @callback = callback
        @log = log
        super(interval, repeat)
      end

      def on_timer
        @callback.call
      rescue
        @log.error $!.to_s
        @log.error_backtrace
      end
    end

    def start
      @loop = Coolio::Loop.new
      @timer = TimerWatcher.new(@interval, true, log, &method(:update_monitor_info))
      @loop.attach(@timer)
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @loop.watchers.each {|w| w.detach }
      @loop.stop
      @thread.join
    end

    def run
      @loop.run
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def update_monitor_info
      @monitor_agent.plugins_info_all.each do |info|
        @monitor_info.each do |name, metric|
          if info[name]
            metric.set(labels(info), info[name])
          end
        end
      end
    end

    def labels(plugin_info)
      @base_labels.merge(
        plugin_id: plugin_info["plugin_id"],
        plugin_category: plugin_info["plugin_category"],
        type: plugin_info["type"],
      )
    end
  end
end
