require 'fluent/input'
require 'fluent/plugin/in_monitor_agent'
require 'fluent/plugin/prometheus'

module Fluent
  class PrometheusTailMonitorInput < Input
    Plugin.register_input('prometheus_tail_monitor', self)

    config_param :interval, :time, :default => 5
    attr_reader :registry

    MONITOR_IVARS = [
      :tails,
    ]

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      hostname = Socket.gethostname
      expander = Fluent::Prometheus.placeholder_expander(log)
      placeholders = expander.prepare_placeholders({'hostname' => hostname})
      @base_labels = Fluent::Prometheus.parse_labels_elements(conf)
      @base_labels.each do |key, value|
        @base_labels[key] = expander.expand(value, placeholders)
      end

      if defined?(Fluent::Plugin) && defined?(Fluent::Plugin::MonitorAgentInput)
        # from v0.14.6
        @monitor_agent = Fluent::Plugin::MonitorAgentInput.new
      else
        @monitor_agent = Fluent::MonitorAgentInput.new
      end

      @metrics = {
        position: @registry.gauge(
          :fluentd_tail_file_position,
          'Current position of file.'),
        inode: @registry.gauge(
          :fluentd_tail_file_inode,
          'Current inode of file.'),
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
      super
      @loop = Coolio::Loop.new
      @timer = TimerWatcher.new(@interval, true, log, &method(:update_monitor_info))
      @loop.attach(@timer)
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      super
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
      opts = {
        ivars: MONITOR_IVARS,
      }

      agent_info = @monitor_agent.plugins_info_all(opts).select {|info|
        info['type'] == 'tail'.freeze
      }

      agent_info.each do |info|
        tails = info['instance_variables'][:tails]
        next if tails.nil?

        tails.each do |_, watcher|
          # Access to internal variable of internal class...
          # Very fragile implementation
          pe = watcher.instance_variable_get(:@pe)
          label = labels(info, watcher.path)
          @metrics[:inode].set(label, pe.read_inode)
          @metrics[:position].set(label, pe.read_pos)
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
  end
end
