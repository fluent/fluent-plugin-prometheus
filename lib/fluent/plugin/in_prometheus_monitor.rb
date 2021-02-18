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
      expander_builder = Fluent::Plugin::Prometheus.placeholder_expander(log)
      expander = expander_builder.build({ 'hostname' => hostname, 'worker_id' => fluentd_worker_id })
      @base_labels = parse_labels_elements(conf)
      @base_labels.each do |key, value|
        unless value.is_a?(String)
          raise Fluent::ConfigError, "record accessor syntax is not available in prometheus_monitor"
        end
        @base_labels[key] = expander.expand(value)
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

      @buffer_newest_timekey = get_gauge(
        :fluentd_status_buffer_newest_timekey,
        'Newest timekey in buffer.')
      @buffer_oldest_timekey = get_gauge(
        :fluentd_status_buffer_oldest_timekey,
        'Oldest timekey in buffer.')
      buffer_queue_length = get_gauge(
        :fluentd_status_buffer_queue_length,
        'Current buffer queue length.')
      buffer_total_queued_size = get_gauge(
        :fluentd_status_buffer_total_bytes,
        'Current total size of queued buffers.')
      retry_counts = get_gauge(
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
            metric.set(info[name], labels: label)
          end
        end

        timekeys = info["buffer_timekeys"]
        if timekeys && !timekeys.empty?
          @buffer_newest_timekey.set(timekeys.max, labels: label)
          @buffer_oldest_timekey.set(timekeys.min, labels: label)
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

    def get_gauge(name, docstring)
      if @registry.exist?(name)
        @registry.get(name)
      else
        @registry.gauge(name, docstring: docstring, labels: @base_labels.keys + [:plugin_id, :plugin_category, :type])
      end
    end
  end
end
