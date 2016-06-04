require 'fluent/output'
require 'fluent/plugin/prometheus'

module Fluent
  class PrometheusOutput < Output
    Plugin.register_output('prometheus', self)
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

    def emit(tag, es, chain)
      instrument(tag, es, @metrics)
      chain.next
    end
  end
end
