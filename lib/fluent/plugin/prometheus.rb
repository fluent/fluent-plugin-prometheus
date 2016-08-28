require 'prometheus/client'
require 'prometheus/client/formats/text'

module Fluent
  module Prometheus
    class AlreadyRegisteredError < StandardError; end

    def self.parse_labels_elements(conf)
      labels = conf.elements.select { |e| e.name == 'labels' }
      if labels.size > 1
        raise ConfigError, "labels section must have at most 1"
      end

      base_labels = {}
      unless labels.empty?
        labels.first.each do |key, value|
          labels.first.has_key?(key)
          base_labels[key.to_sym] = value
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
        when 'histogram'
          metrics << Fluent::Prometheus::Histogram.new(element, registry, labels)
        else
          raise ConfigError, "type option must be 'counter', 'gauge', 'summary' or 'histogram'"
        end
      }
      metrics
    end

    def self.placeholder_expander(log)
      # Use internal class in order to expand placeholder
      if defined?(Fluent::Filter) # for v0.12, built-in PlaceholderExpander
        begin
          require 'fluent/plugin/filter_record_transformer'
          if defined?(Fluent::Plugin::RecordTransformerFilter::PlaceholderExpander)
            # for v0.14
            return Fluent::Plugin::RecordTransformerFilter::PlaceholderExpander.new(log: log)
          else
            # for v0.12
            return Fluent::RecordTransformerFilter::PlaceholderExpander.new(log: log)
          end
        rescue LoadError => e
          raise ConfigError, "cannot find filter_record_transformer plugin: #{e.message}"
        end
      else # for v0.10, use PlaceholderExapander in fluent-plugin-record-reformer plugin
        begin
          require 'fluent/plugin/out_record_reformer.rb'
          return Fluent::RecordReformerOutput::PlaceholderExpander.new(log: log)
        rescue LoadError => e
          raise ConfigError, "cannot find fluent-plugin-record-reformer: #{e.message}"
        end
      end
    end

    def configure(conf)
      super
      @placeholder_expander = Fluent::Prometheus.placeholder_expander(log)
      @hostname = Socket.gethostname
    end

    def instrument(tag, es, metrics)
      placeholder_values = {
        'tag' => tag,
        'hostname' => @hostname,
      }

      es.each do |time, record|
        placeholders = record.merge(placeholder_values)
        placeholders = @placeholder_expander.prepare_placeholders(placeholders)
        metrics.each do |metric|
          begin
            metric.instrument(record, @placeholder_expander, placeholders)
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
        ['name', 'desc'].each do |key|
          if element[key].nil?
            raise ConfigError, "metric requires '#{key}' option"
          end
        end
        @type = element['type']
        @name = element['name']
        @key = element['key']
        @desc = element['desc']

        @base_labels = Fluent::Prometheus.parse_labels_elements(element)
        @base_labels = labels.merge(@base_labels)
      end

      def labels(record, expander, placeholders)
        label = {}
        @base_labels.each do |k, v|
          label[k] = expander.expand(v, placeholders)
        end
        label
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
        if @key.nil?
          raise ConfigError, "gauge metric requires 'key' option"
        end

        begin
          @gauge = registry.gauge(element['name'].to_sym, element['desc'])
        rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
          @gauge = Fluent::Prometheus::Metric.get(registry, element['name'].to_sym, :gauge, element['desc'])
        end
      end

      def instrument(record, expander, placeholders)
        if record[@key]
          @gauge.set(labels(record, expander, placeholders), record[@key])
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
      end

      def instrument(record, expander, placeholders)
        # use record value of the key if key is specified, otherwise just increment
        value = @key ? record[@key] : 1

        # ignore if record value is nil
        return if value.nil?

        @counter.increment(labels(record, expander, placeholders), value)
      end
    end

    class Summary < Metric
      def initialize(element, registry, labels)
        super
        if @key.nil?
          raise ConfigError, "summary metric requires 'key' option"
        end

        begin
          @summary = registry.summary(element['name'].to_sym, element['desc'])
        rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
          @summary = Fluent::Prometheus::Metric.get(registry, element['name'].to_sym, :summary, element['desc'])
        end
      end

      def instrument(record, expander, placeholders)
        if record[@key]
          @summary.observe(labels(record, expander, placeholders), record[@key])
        end
      end
    end

    class Histogram < Metric
      def initialize(element, registry, labels)
        super
        if @key.nil?
          raise ConfigError, "histogram metric requires 'key' option"
        end

        begin
          if element['buckets']
            buckets = element['buckets'].split(/,/).map(&:strip).map do |e|
              e[/\A\d+.\d+\Z/] ? e.to_f : e.to_i
            end
            @histogram = registry.histogram(element['name'].to_sym, element['desc'], {}, buckets)
          else
            @histogram = registry.histogram(element['name'].to_sym, element['desc'])
          end
        rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
          @histogram = Fluent::Prometheus::Metric.get(registry, element['name'].to_sym, :histogram, element['desc'])
        end
      end

      def instrument(record, expander, placeholders)
        if record[@key]
          @histogram.observe(labels(record, expander, placeholders), record[@key])
        end
      end
    end
  end
end
