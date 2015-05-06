require 'fluent/plugin/prometheus'

module Fluent
  class PrometheusFilter < Filter
    Plugin.register_filter('prometheus', self)
    include Fluent::Prometheus

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def configure(conf)
      super
      labels = Fluent::Prometheus.parse_labels_elements(conf)
      @metrics = Fluent::Prometheus.parse_metrics_elements(conf, @registry, labels)
    end

    def filter_stream(tag, es)
      instrument(tag, es, @metrics)
      es
    end
  end if defined?(Filter)
end
