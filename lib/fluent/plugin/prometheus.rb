require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'fluent/plugin/prometheus/placeholder_expander'
require 'fluent/plugin/prometheus/data_store'

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

      def self.start_retention_threads(metrics, registry, thread_create, thread_running, log)
        metrics.select { |metric| metric.has_retention? }.each do |metric|
          thread_create.call("prometheus_retention_#{metric.name}".to_sym) do
            while thread_running.call()
              metric.remove_expired_metrics(registry, log)
              sleep(metric.retention_check_interval)
            end
          end
        end
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

      def initialize
        super
        ::Prometheus::Client.config.data_store = Fluent::Plugin::Prometheus::DataStore.new
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
        attr_reader :retention
        attr_reader :retention_check_interval

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
          @retention = element['retention'].to_i
          @retention_check_interval = element.fetch('retention_check_interval', 60).to_i
          if has_retention?
            @last_modified_store = LastModifiedStore.new
          end

          @base_labels = Fluent::Plugin::Prometheus.parse_labels_elements(element)
          @base_labels = labels.merge(@base_labels)
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

        def set_value?(value)
          if value
            return true
          end
          false
        end

        def instrument(record, expander)
          value = self.value(record)
          if self.set_value?(value)
            labels = labels(record, expander)
            set_value(value, labels)
            if has_retention?
              @last_modified_store.set_last_updated(labels)
            end
          end
        end

        def has_retention?
          @retention > 0
        end

        def remove_expired_metrics(registry, log)
          if has_retention?
            metric = registry.get(@name)

            expiration_time = Time.now - @retention
            expired_label_sets = @last_modified_store.get_labels_not_modified_since(expiration_time)

            expired_label_sets.each { |expired_label_set|
              log.debug "Metric #{@name} with labels #{expired_label_set} expired. Removing..."
              metric.remove(expired_label_set) # this method is supplied by the require at the top of this method
              @last_modified_store.remove(expired_label_set)
            }
          else
            log.warn('remove_expired_metrics should not be called when retention is not set for this metric!')
          end
        end

        class LastModifiedStore
          def initialize
            @internal_store = Hash.new
            @lock = Monitor.new
          end

          def synchronize
            @lock.synchronize { yield }
          end

          def set_last_updated(labels)
            synchronize do
              @internal_store[labels] = Time.now
            end
          end

          def remove(labels)
            synchronize do
              @internal_store.delete(labels)
            end
          end

          def get_labels_not_modified_since(time)
            synchronize do
              @internal_store.select { |k, v| v < time }.keys
            end
          end
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
        end

        def value(record)
          if @key.is_a?(String)
            record[@key]
          else
            @key.call(record)
          end
        end

        def set_value(value, labels)
          @gauge.set(value, labels: labels)
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
        end

        def value(record)
          if @key.nil?
            1
          elsif @key.is_a?(String)
            record[@key]
          else
            @key.call(record)
          end
        end

        def set_value?(value)
          !value.nil?
        end

        def set_value(value, labels)
          @counter.increment(by: value, labels: labels)
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
        end

        def value(record)
          if @key.is_a?(String)
            record[@key]
          else
            @key.call(record)
          end
        end

        def set_value(value, labels)
          @summary.observe(value, labels: labels)
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
        end

        def value(record)
          if @key.is_a?(String)
            record[@key]
          else
            @key.call(record)
          end
        end

        def set_value(value, labels)
          @histogram.observe(value, labels: labels)
        end
      end
    end
  end
end
