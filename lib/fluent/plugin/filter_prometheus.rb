require 'fluent/plugin/prometheus'
require 'fluent/plugin/filter'

module Fluent::Plugin
  class PrometheusFilter < Fluent::Plugin::Filter
    Fluent::Plugin.register_filter('prometheus', self)
    include Fluent::Plugin::Prometheus

    def initialize
      super
      @registry = ::Prometheus::Client.registry
    end

    def multi_workers_ready?
      true
    end

    def configure(conf)
      super
      labels = Fluent::Plugin::Prometheus.parse_labels_elements(conf)
      @metrics = Fluent::Plugin::Prometheus.parse_metrics_elements(conf, @registry, labels)
    end

    def filter_stream(tag, es)
      instrument(tag, es, @metrics)
      es
    end
  end
end
