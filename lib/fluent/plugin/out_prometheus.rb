require 'fluent/plugin/output'
require 'fluent/plugin/prometheus'

module Fluent::Plugin
  class PrometheusOutput < Fluent::Plugin::Output
    Fluent::Plugin.register_output('prometheus', self)
    include Fluent::Plugin::PrometheusLabelParser
    include Fluent::Plugin::Prometheus

    # a record which cannot be instrumented is emitted as an error event, the
    # same way as filter_prometheus does. Filter gets its router from the
    # plugin base, while Output has to ask for the helper.
    helpers :event_emitter

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
      @metrics = Fluent::Plugin::Prometheus.parse_metrics_elements(conf, @registry, labels, metric_options)
    end

    def process(tag, es)
      instrument(tag, es, @metrics)
    end
  end
end
