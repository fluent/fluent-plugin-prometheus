require 'fluent/plugin/output'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  class PrometheusOutput < Fluent::Plugin::Output
    Fluent::Plugin.register_output('prometheus', self)
    include Fluent::Plugin::Prometheus

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      labels = Fluent::Plugin::Prometheus.parse_labels_elements(conf)
      @metrics = Fluent::Plugin::Prometheus.parse_metrics_elements(conf, @registry, labels)
    end

    def process(tag, es)
      instrument(tag, es, @metrics)
    end
  end
end
