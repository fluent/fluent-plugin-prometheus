require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'fluent/plugin/prometheus/placeholder_expander'

module Fluent
  module Plugin
    module PrometheusLabelParser
      def configure(conf)
        super
        # Check if running with multiple workers
        sysconf = if self.respond_to?(:owner) && owner.respond_to?(:system_config)
          owner.system_config
        elsif self.respond_to?(:system_config)
          self.system_config
        else
          nil
        end
        @multi_worker = sysconf && sysconf.workers ? (sysconf.workers > 1) : false
      end

      def parse_labels_elements(conf)
        base_labels = Fluent::Plugin::Prometheus.parse_labels_elements(conf)

        if @multi_worker
          base_labels[:worker_id] = fluentd_worker_id.to_s
        end

        base_labels
      end
    end

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

            # use RecordAccessor only for $. and $[ syntax
            # otherwise use the value as is or expand the value by RecordTransformer for ${} syntax
            if value.start_with?('$.') || value.start_with?('$[')
              base_labels[key.to_sym] = PluginHelper::RecordAccessor::Accessor.new(value)
            else
              base_labels[key.to_sym] = value
            end
          end
        end

        base_labels
      end

      def self.parse_initlabels_elements(conf, base_labels)
        base_initlabels = []

        # We first treat the special case of RecordAccessors and Placeholders labels if any declared
        conf.elements.select { |e| e.name == 'initlabels' }.each { |block|
          initlabels = {}

          block.each do |key, value|
            if not base_labels.has_key? key.to_sym
              raise ConfigError, "Key #{key} in <initlabels> is non existent in <labels> for metric #{conf['name']}"
            end

            if value.start_with?('$.') || value.start_with?('$[') || value.start_with?('${')
              raise ConfigError, "Cannot use RecordAccessor or placeholder #{value} (key #{key}) in a <initlabels> in metric #{conf['name']}"
            end

            base_label_value = base_labels[key.to_sym]

            if !(base_label_value.class == Fluent::PluginHelper::RecordAccessor::Accessor) && ! (base_label_value.start_with?('${') )
              raise ConfigError, "Cannot set <initlabels> on non RecordAccessor/Placeholder key #{key} (value #{value}) in metric #{conf['name']}"
            end

            if base_label_value == '${worker_id}' || base_label_value == '${hostname}'
              raise ConfigError, "Cannot set <initlabels> on reserved placeholder #{base_label_value} for key #{key} in metric #{conf['name']}"
            end
            
            initlabels[key.to_sym] = value
          end

          # Now adding all labels that are not RecordAccessor nor Placeholder labels as is
          base_labels.each do |key, value|
            if base_labels[key.to_sym].class != Fluent::PluginHelper::RecordAccessor::Accessor
              if value == '${worker_id}'
                # We retrieve fluentd_worker_id this way to not overcomplicate the code
                initlabels[key.to_sym] = (ENV['SERVERENGINE_WORKER_ID'] || 0).to_i
              elsif value == '${hostname}'
                initlabels[key.to_sym] = Socket.gethostname
              elsif !(value.start_with?('${'))
                initlabels[key.to_sym] = value
              end
            end
          end

          base_initlabels << initlabels
        }

        # Testing for RecordAccessor/Placeholder labels missing a declaration in <initlabels> blocks
        base_labels.each do |key, value|
          if value.class == Fluent::PluginHelper::RecordAccessor::Accessor || value.start_with?('${')
            if not base_initlabels.map(&:keys).flatten.include? (key.to_sym)
                raise ConfigError, "RecordAccessor/Placeholder key #{key} with value #{value} has not been set in a <initlabels> for initialized metric #{conf['name']}"
            end
          end
        end

        if base_initlabels.length == 0
          # There were no RecordAccessor nor Placeholder labels, we blunty retrieve the static base_labels
          base_initlabels << base_labels
        end

        base_initlabels
      end

      def self.parse_metrics_elements(conf, registry, labels = {})
        metrics = []
        conf.elements.select { |element|
          element.name == 'metric'
        }.each { |element|
          if element.has_key?('key') && (element['key'].start_with?('$.') || element['key'].start_with?('$['))
            value = element['key']
            element['key'] = PluginHelper::RecordAccessor::Accessor.new(value)
          end
          case element['type']
          when 'summary'
            metrics << Fluent::Plugin::Prometheus::Summary.new(element, registry, labels)
          when 'gauge'
            metrics << Fluent::Plugin::Prometheus::Gauge.new(element, registry, labels)
          when 'counter'
            metrics << Fluent::Plugin::Prometheus::Counter.new(element, registry, labels)
          when 'histogram'
            metrics << Fluent::Plugin::Prometheus::Histogram.new(element, registry, labels)
          else
            raise ConfigError, "type option must be 'counter', 'gauge', 'summary' or 'histogram'"
          end
        }
        metrics
      end

      def self.placeholder_expander(log)
        Fluent::Plugin::Prometheus::ExpandBuilder.new(log: log)
      end

      def stringify_keys(hash_to_stringify)
        # Adapted from: https://www.jvt.me/posts/2019/09/07/ruby-hash-keys-string-symbol/
        hash_to_stringify.map do |k,v|
          value_or_hash = if v.instance_of? Hash
                            stringify_keys(v)
                          else
                            v
                          end
          [k.to_s, value_or_hash]
        end.to_h
      end

      def configure(conf)
        super
        @placeholder_values = {}
        @placeholder_expander_builder = Fluent::Plugin::Prometheus.placeholder_expander(log)
        @hostname = Socket.gethostname
      end

      def instrument_single(tag, time, record, metrics)
        @placeholder_values[tag] ||= {
          'tag' => tag,
          'hostname' => @hostname,
          'worker_id' => fluentd_worker_id,
        }

        record = stringify_keys(record)
        placeholders = record.merge(@placeholder_values[tag])
        expander = @placeholder_expander_builder.build(placeholders)
        metrics.each do |metric|
          begin
            metric.instrument(record, expander)
          rescue => e
            log.warn "prometheus: failed to instrument a metric.", error_class: e.class, error: e, tag: tag, name: metric.name
            router.emit_error_event(tag, time, record, e)
          end
        end
      end

      def instrument(tag, es, metrics)
        placeholder_values = {
          'tag' => tag,
          'hostname' => @hostname,
          'worker_id' => fluentd_worker_id,
        }

        es.each do |time, record|
          record = stringify_keys(record)
          placeholders = record.merge(placeholder_values)
          expander = @placeholder_expander_builder.build(placeholders)
          metrics.each do |metric|
            begin
              metric.instrument(record, expander)
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
          element['initialized'].nil? ? @initialized = false : @initialized = element['initialized'] == 'true'
          
          @base_labels = Fluent::Plugin::Prometheus.parse_labels_elements(element)
          @base_labels = labels.merge(@base_labels)

          if @initialized
            @base_initlabels = Fluent::Plugin::Prometheus.parse_initlabels_elements(element, @base_labels)
          end
        end

        def self.init_label_set(metric, base_initlabels, base_labels)
          base_initlabels.each { |initlabels|
            # Should never happen, but handy test should code evolution break current implementation
            if initlabels.keys.sort != base_labels.keys.sort
              raise ConfigError, "initlabels for metric #{metric.name} must have the same signature than labels " \
                                "(initlabels given: #{initlabels.keys} vs." \
                                " expected from labels: #{base_labels.keys})"
            end

            metric.init_label_set(initlabels)
          }
        end

        def labels(record, expander)
          label = {}
          @base_labels.each do |k, v|
            if v.is_a?(String)
              label[k] = expander.expand(v)
            else
              label[k] = v.call(record)
            end
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
            @gauge = registry.gauge(element['name'].to_sym, docstring: element['desc'], labels: @base_labels.keys)
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @gauge = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :gauge, element['desc'])
          end

          if @initialized
            Fluent::Plugin::Prometheus::Metric.init_label_set(@gauge, @base_initlabels, @base_labels)
          end
        end

        def instrument(record, expander)
          if @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end
          if value
            @gauge.set(value, labels: labels(record, expander))
          end
        end
      end

      class Counter < Metric
        def initialize(element, registry, labels)
          super
          begin
            @counter = registry.counter(element['name'].to_sym, docstring: element['desc'], labels: @base_labels.keys)
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @counter = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :counter, element['desc'])
          end

          if @initialized
            Fluent::Plugin::Prometheus::Metric.init_label_set(@counter, @base_initlabels, @base_labels)
          end
        end

        def instrument(record, expander)
          # use record value of the key if key is specified, otherwise just increment
          if @key.nil?
            value = 1
          elsif @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end

          # ignore if record value is nil
          return if value.nil?

          @counter.increment(by: value, labels: labels(record, expander))
        end
      end

      class Summary < Metric
        def initialize(element, registry, labels)
          super
          if @key.nil?
            raise ConfigError, "summary metric requires 'key' option"
          end

          begin
            @summary = registry.summary(element['name'].to_sym, docstring: element['desc'], labels: @base_labels.keys)
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @summary = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :summary, element['desc'])
          end

          if @initialized
            Fluent::Plugin::Prometheus::Metric.init_label_set(@summary, @base_initlabels, @base_labels)
          end
        end

        def instrument(record, expander)
          if @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end
          if value
            @summary.observe(value, labels: labels(record, expander))
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
              @histogram = registry.histogram(element['name'].to_sym, docstring: element['desc'], labels: @base_labels.keys, buckets: buckets)
            else
              @histogram = registry.histogram(element['name'].to_sym, docstring: element['desc'], labels: @base_labels.keys)
            end
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            @histogram = Fluent::Plugin::Prometheus::Metric.get(registry, element['name'].to_sym, :histogram, element['desc'])
          end

          if @initialized
            Fluent::Plugin::Prometheus::Metric.init_label_set(@histogram, @base_initlabels, @base_labels)
          end
        end

        def instrument(record, expander)
          if @key.is_a?(String)
            value = record[@key]
          else
            value = @key.call(record)
          end
          if value
            @histogram.observe(value, labels: labels(record, expander))
          end
        end
      end
    end
  end
end
