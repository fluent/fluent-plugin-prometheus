require 'fluent/plugin/output'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  class PrometheusOutput < Fluent::Plugin::Output
    Fluent::Plugin.register_output('prometheus', self)
    include Fluent::Plugin::PrometheusLabelParser
    include Fluent::Plugin::Prometheus

    helpers :timer

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def multi_workers_ready?
      true
    end

    def configure(conf)
      super
      labels = parse_labels_elements(conf)
      @metrics = Fluent::Plugin::Prometheus.parse_metrics_elements(conf, @registry, labels)
    end

    def start
      super
      Fluent::Plugin::Prometheus.start_retention_checks(
        @metrics,
        @registry,
        @log,
        method(:timer_execute)
      )
    end

    def process(tag, es)
      instrument(tag, es, @metrics)
    end
  end
end
