require 'fluent/plugin/input'
require 'fluent/plugin/in_monitor_agent'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  class PrometheusOutputMonitorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('prometheus_output_monitor', self)
    include Fluent::Plugin::PrometheusLabelParser

    helpers :timer

    config_param :interval, :time, default: 5
    config_param :gauge_all, :bool, default: true
    attr_reader :registry

    MONITOR_IVARS = [
      :retry,

      :num_errors,
      :emit_count,

      # for v0.12
      :last_retry_time,

      # from v0.14
      :emit_records,
      :write_count,
      :rollback_count,

      # from v1.6.0
      :flush_time_count,
      :slow_flush_count,
    ]

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
          raise Fluent::ConfigError, "record accessor syntax is not available in prometheus_output_monitor"
        end
        @base_labels[key] = expander.expand(value)
      end

      @monitor_agent = Fluent::Plugin::MonitorAgentInput.new

      @gauge_or_counter = @gauge_all ? :gauge : :counter
    end

    def start
      super

      @metrics = {
        # Buffer metrics
        buffer_total_queued_size: get_gauge(
          :fluentd_output_status_buffer_total_bytes,
          'Current total size of stage and queue buffers.'),
        buffer_stage_length: get_gauge(
          :fluentd_output_status_buffer_stage_length,
          'Current length of stage buffers.'),
        buffer_stage_byte_size: get_gauge(
          :fluentd_output_status_buffer_stage_byte_size,
          'Current total size of stage buffers.'),
        buffer_queue_length: get_gauge(
          :fluentd_output_status_buffer_queue_length,
          'Current length of queue buffers.'),
        buffer_queue_byte_size: get_gauge(
          :fluentd_output_status_buffer_queue_byte_size,
          'Current total size of queue buffers.'),
        buffer_available_buffer_space_ratios: get_gauge(
          :fluentd_output_status_buffer_available_space_ratio,
          'Ratio of available space in buffer.'),
        buffer_newest_timekey: get_gauge(
          :fluentd_output_status_buffer_newest_timekey,
          'Newest timekey in buffer.'),
        buffer_oldest_timekey: get_gauge(
          :fluentd_output_status_buffer_oldest_timekey,
          'Oldest timekey in buffer.'),

        # Output metrics
        retry_counts: get_gauge_or_counter(
          :fluentd_output_status_retry_count,
          'Current retry counts.'),
        num_errors: get_gauge_or_counter(
          :fluentd_output_status_num_errors,
          'Current number of errors.'),
        emit_count: get_gauge_or_counter(
          :fluentd_output_status_emit_count,
          'Current emit counts.'),
        emit_records: get_gauge_or_counter(
          :fluentd_output_status_emit_records,
          'Current emit records.'),
        write_count: get_gauge_or_counter(
          :fluentd_output_status_write_count,
          'Current write counts.'),
        rollback_count: get_gauge(
          :fluentd_output_status_rollback_count,
          'Current rollback counts.'),
        flush_time_count: get_gauge_or_counter(
          :fluentd_output_status_flush_time_count,
          'Total flush time.'),
        slow_flush_count: get_gauge_or_counter(
          :fluentd_output_status_slow_flush_count,
          'Current slow flush counts.'),
        retry_wait: get_gauge(
          :fluentd_output_status_retry_wait,
          'Current retry wait'),
      }
      timer_execute(:in_prometheus_output_monitor, @interval, &method(:update_monitor_info))
    end

    def update_monitor_info
      opts = {
        ivars: MONITOR_IVARS,
        with_retry: true,
      }

      agent_info = @monitor_agent.plugins_info_all(opts).select {|info|
        info['plugin_category'] == 'output'.freeze
      }

      monitor_info = {
        # buffer metrics
        'buffer_total_queued_size' => [@metrics[:buffer_total_queued_size]],
        'buffer_stage_length' => [@metrics[:buffer_stage_length]],
        'buffer_stage_byte_size' => [@metrics[:buffer_stage_byte_size]],
        'buffer_queue_length' => [@metrics[:buffer_queue_length]],
        'buffer_queue_byte_size' => [@metrics[:buffer_queue_byte_size]],
        'buffer_available_buffer_space_ratios' => [@metrics[:buffer_available_buffer_space_ratios]],
        'buffer_newest_timekey' => [@metrics[:buffer_newest_timekey]],
        'buffer_oldest_timekey' => [@metrics[:buffer_oldest_timekey]],

        # output metrics
        'retry_count' => [@metrics[:retry_counts], @metrics[:num_errors]],
        # Needed since Fluentd v1.14 due to metrics extensions.
        'write_count' => [@metrics[:write_count]],
        'emit_count' => [@metrics[:emit_count]],
        'emit_records' => [@metrics[:emit_records]],
        'rollback_count' => [@metrics[:rollback_count]],
        'flush_time_count' => [@metrics[:flush_time_count]],
        'slow_flush_count' => [@metrics[:slow_flush_count]],
      }
      # No needed for Fluentd v1.14 but leave as-is for backward compatibility.
      instance_vars_info = {
        num_errors: @metrics[:num_errors],
        write_count: @metrics[:write_count],
        emit_count: @metrics[:emit_count],
        emit_records: @metrics[:emit_records],
        rollback_count: @metrics[:rollback_count],
        flush_time_count: @metrics[:flush_time_count],
        slow_flush_count: @metrics[:slow_flush_count],
      }

      agent_info.each do |info|
        label = labels(info)

        monitor_info.each do |name, metrics|
          metrics.each do |metric|
            if info[name]
              if metric.is_a?(::Prometheus::Client::Gauge)
                metric.set(info[name], labels: label)
              elsif metric.is_a?(::Prometheus::Client::Counter)
                metric.increment(by: info[name] - metric.get(labels: label), labels: label)
              end
            end
          end
        end

        if info['instance_variables']
          instance_vars_info.each do |name, metric|
            if info['instance_variables'][name]
              if metric.is_a?(::Prometheus::Client::Gauge)
                metric.set(info['instance_variables'][name], labels: label)
              elsif metric.is_a?(::Prometheus::Client::Counter)
                metric.increment(by: info['instance_variables'][name] - metric.get(labels: label), labels: label)
              end
            end
          end
        end

        # compute current retry_wait
        if info['retry']
          next_time = info['retry']['next_time']
          start_time = info['retry']['start']
          if start_time.nil? && info['instance_variables']
            # v0.12 does not include start, use last_retry_time instead
            start_time = info['instance_variables'][:last_retry_time]
          end

          wait = 0
          if next_time && start_time
            wait = next_time - start_time
          end
          @metrics[:retry_wait].set(wait.to_f, labels: label)
        end
      end
    end

    def labels(plugin_info)
      @base_labels.merge(
        plugin_id: plugin_info["plugin_id"],
        type: plugin_info["type"],
      )
    end

    def get_gauge(name, docstring)
      if @registry.exist?(name)
        @registry.get(name)
      else
        @registry.gauge(name, docstring: docstring, labels: @base_labels.keys + [:plugin_id, :type])
      end
    end

    def get_gauge_or_counter(name, docstring)
      if @registry.exist?(name)
        @registry.get(name)
      else
        @registry.public_send(@gauge_or_counter, name, docstring: docstring, labels: @base_labels.keys + [:plugin_id, :type])
      end
    end
  end
end
