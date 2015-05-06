require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'fluent/mixin/rewrite_tag_name'

module Fluent
  module Prometheus
    class AlreadyRegisteredError < StandardError; end

    def self.parse_labels_elements(conf)
      labels = conf.elements.select { |e| e.name == 'labels' }
      if labels.size > 1
        raise ConfigError, "labels section must have at most 1"
      end

      placeholder_expander = Fluent::Mixin::RewriteTagName::PlaceholderExpander.new
      placeholder_expander.set_hostname(Socket.gethostname)

      base_labels = {}
      unless labels.empty?
        labels.first.each do |key, value|
          labels.first.has_key?(key)
          base_labels[key.to_sym] = placeholder_expander.expand(value)
        end
      end

      base_labels
    end

    def self.parse_metrics_elements(conf, registry, labels = {})
      metrics = []
      conf.elements.select { |element|
        element.name == 'metric'
      }.each { |element|
        case element['type']
        when 'summary'
          metrics << Fluent::Prometheus::Summary.new(element, registry, labels)
        when 'gauge'
          metrics << Fluent::Prometheus::Gauge.new(element, registry, labels)
        when 'counter'
          metrics << Fluent::Prometheus::Counter.new(element, registry, labels)
        else
          raise ConfigError, "type option must be 'counter', 'gauge' or 'summary'"
        end
      }
      metrics
    end

    def instrument(tag, es, metrics)
      es.each do |time, record|
        metrics.each do |metric|
          begin
            metric.instrument(record)
          rescue => e
            log.warn "prometheus: failed to instrument a metric.", error_class: e.class, error: e, tag: tag, name: metric.name
            router.emit_error_event(tag, time, record, e)
          end
        end
      end
    end

    class Metric
      attr_reader :type
      attr_reader :name
      attr_reader :key
      attr_reader :desc

      def initialize(element, registry, labels)
        ['name', 'desc', 'key'].each do |key|
          if element[key].nil?
            raise ConfigError, "metric must have #{key} option"
          end
        end
        @type = element['type']
        @name = element['name']
        @key = element['key']
        @desc = element['desc']

        @base_labels = Fluent::Prometheus.parse_labels_elements(element)
        @base_labels = labels.merge(@base_labels)
      end

      def labels(record)
        # TODO: enable to specify labels with record value
        @base_labels
      end


      def self.get(registry, name, type, docstring)
        metric = registry.get(name)

        # should have same type, docstring
        if metric.type != type
          raise AlreadyRegisteredError, "#{name} has already been registered as #{type} type"
        end
        if metric.docstring != docstring
          raise AlreadyRegisteredError, "#{name} has already been registered with different docstring"
        end

        metric
      end
    end

    class Gauge < Metric
      def initialize(element, registry, labels)
        super
        begin
          @gauge = registry.gauge(element['name'].to_sym, element['desc'])
        rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
          @gauge = Fluent::Prometheus::Metric.get(registry, element['name'].to_sym, :gauge, element['desc'])
        end
        @key = element['key']
      end

      def instrument(record)
        if record[@key]
          @gauge.set(labels(record), record[@key])
        end
      end
    end

    class Counter < Metric
      def initialize(element, registry, labels)
        super
        begin
          @counter = registry.counter(element['name'].to_sym, element['desc'])
        rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
          @counter = Fluent::Prometheus::Metric.get(registry, element['name'].to_sym, :counter, element['desc'])
        end
        @key = element['key']
      end

      def instrument(record)
        if record[@key]
          @counter.increment(labels(record), record[@key])
        end
      end
    end

    class Summary < Metric
      def initialize(element, registry, labels)
        super
        begin
          @summary = registry.summary(element['name'].to_sym, element['desc'])
        rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
          @summary = Fluent::Prometheus::Metric.get(registry, element['name'].to_sym, :summary, element['desc'])
        end
        @key = element['key']
      end

      def instrument(record)
        if record[@key]
          @summary.add(labels(record), record[@key])
        end
      end
    end
  end
end
