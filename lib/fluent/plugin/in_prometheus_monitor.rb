require 'fluent/plugin/input'
require 'fluent/plugin/in_monitor_agent'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  class PrometheusMonitorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('prometheus_monitor', self)
    include Fluent::Plugin::PrometheusLabelParser

    helpers :timer

    config_param :interval, :time, default: 5
    attr_reader :registry

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def multi_workers_ready?
      true
    end

    def configure(conf)
      super
      hostname = Socket.gethostname
      expander = Fluent::Plugin::Prometheus.placeholder_expander(log)
      placeholders = expander.prepare_placeholders({'hostname' => hostname, 'worker_id' => fluentd_worker_id})
      @base_labels = parse_labels_elements(conf)
      @base_labels.each do |key, value|
        unless value.is_a?(String)
          raise Fluent::ConfigError, "record accessor syntax is not available in prometheus_monitor"
        end
        @base_labels[key] = expander.expand(value, placeholders)
      end

      if defined?(Fluent::Plugin) && defined?(Fluent::Plugin::MonitorAgentInput)
        # from v0.14.6
        @monitor_agent = Fluent::Plugin::MonitorAgentInput.new
      else
        @monitor_agent = Fluent::MonitorAgentInput.new
      end

    end

    def start
      super

      @buffer_newest_timekey = @registry.gauge(
        :fluentd_status_buffer_newest_timekey,
        'Newest timekey in buffer.')
      @buffer_oldest_timekey = @registry.gauge(
        :fluentd_status_buffer_oldest_timekey,
        'Oldest timekey in buffer.')
      buffer_queue_length = @registry.gauge(
        :fluentd_status_buffer_queue_length,
        'Current buffer queue length.')
      buffer_total_queued_size = @registry.gauge(
        :fluentd_status_buffer_total_bytes,
        'Current total size of queued buffers.')
      retry_counts = @registry.gauge(
        :fluentd_status_retry_count,
        'Current retry counts.')

      @monitor_info = {
        'buffer_queue_length' => buffer_queue_length,
        'buffer_total_queued_size' => buffer_total_queued_size,
        'retry_count' => retry_counts,
      }
      timer_execute(:in_prometheus_monitor, @interval, &method(:update_monitor_info))
    end

    def update_monitor_info
      @monitor_agent.plugins_info_all.each do |info|
        label = labels(info)

        @monitor_info.each do |name, metric|
          if info[name]
            metric.set(label, info[name])
          end
        end

        timekeys = info["buffer_timekeys"]
        if timekeys && !timekeys.empty?
          @buffer_newest_timekey.set(label, timekeys.max)
          @buffer_oldest_timekey.set(label, timekeys.min)
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
