require 'fluent/plugin/input'
require 'fluent/plugin/in_monitor_agent'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  class PrometheusTailMonitorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('prometheus_tail_monitor', self)
    include Fluent::Plugin::PrometheusLabelParser

    helpers :timer

    config_param :interval, :time, default: 5
    attr_reader :registry

    MONITOR_IVARS = [
      :tails,
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
          raise Fluent::ConfigError, "record accessor syntax is not available in prometheus_tail_monitor"
        end
        @base_labels[key] = expander.expand(value)
      end

      @monitor_agent = Fluent::Plugin::MonitorAgentInput.new
    end

    def start
      super

      @metrics = {
        position: get_gauge(
          :fluentd_tail_file_position,
          'Current position of file.'),
        inode: get_gauge(
          :fluentd_tail_file_inode,
          'Current inode of file.'),
        closed_file_metrics: get_gauge(
          :fluentd_tail_file_closed,
          'Number of files closed.'),
        opened_file_metrics: get_gauge(
          :fluentd_tail_file_opened,
          'Number of files opened.'),
        rotated_file_metrics: get_gauge(
          :fluentd_tail_file_rotated,
          'Number of files rotated.'),
      }
      timer_execute(:in_prometheus_tail_monitor, @interval, &method(:update_monitor_info))
    end

    def update_monitor_info
      opts = {
        ivars: MONITOR_IVARS,
      }

      agent_info = @monitor_agent.plugins_info_all(opts).select {|info|
        info['type'] == 'tail'.freeze
      }

      agent_info.each do |info|
        tails = info['instance_variables'][:tails]
        next if tails.nil?

        tails.clone.each do |_, watcher|
          # Access to internal variable of internal class...
          # Very fragile implementation
          pe = watcher.instance_variable_get(:@pe)
          monitor_info = watcher.instance_variable_get(:@metrics)
          label = labels(info, watcher.path)
          @metrics[:inode].set(pe.read_inode, labels: label)
          @metrics[:position].set(pe.read_pos, labels: label)
          unless monitor_info.nil?
            @metrics[:closed_file_metrics].set(monitor_info.closed.get, labels: label)
            @metrics[:opened_file_metrics].set(monitor_info.opened.get, labels: label)
            @metrics[:rotated_file_metrics].set(monitor_info.rotated.get, labels: label)
          end
        end
      end
    end

    def labels(plugin_info, path)
      @base_labels.merge(
        plugin_id: plugin_info["plugin_id"],
        type: plugin_info["type"],
        path: path,
      )
    end

    def get_gauge(name, docstring)
      if @registry.exist?(name)
        @registry.get(name)
      else
        @registry.gauge(name, docstring: docstring, labels: @base_labels.keys + [:plugin_id, :type, :path])
      end
    end
  end
end
