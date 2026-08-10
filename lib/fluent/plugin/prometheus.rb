require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'fluent/clock'
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
      # raised when a metric is about to expand a label set beyond its limit
      class LabelSetLimitError < StandardError; end

      # 0 or less means unlimited. Both limits are unlimited by default, because
      # enabling them changes the existing metrics silently: truncating a label
      # value merges label sets which were distinct so far, and dropping a label
      # set loses the record without any way to recover it. An operator who
      # needs to bound the cardinality has to opt in explicitly.
      DEFAULT_MAX_LABEL_VALUE_LENGTH = 0
      DEFAULT_MAX_SERIES_PER_METRIC = 0
      DEFAULT_IGNORE_ERROR_LOG_INTERVAL = 3600

      # Counts the label sets dropped by max_series_per_metric, so that the
      # drops are visible in Prometheus itself and not only in the Fluentd log.
      DROPPED_LABEL_SETS_METRIC_NAME = :fluentd_prometheus_dropped_label_sets_total
      DROPPED_LABEL_SETS_METRIC_DESC = 'The total number of label sets dropped because the metric reached max_series_per_metric.'

      def self.included(klass)
        klass.class_eval do
          desc 'The maximum length of a label value. Longer values are truncated. 0 (default) means unlimited.'
          config_param :max_label_value_length, :integer, default: DEFAULT_MAX_LABEL_VALUE_LENGTH
          desc 'The maximum number of label sets a metric can hold. Exceeding label sets are dropped. 0 (default) means unlimited.'
          config_param :max_series_per_metric, :integer, default: DEFAULT_MAX_SERIES_PER_METRIC
          desc 'The interval to suppress the repeated same error log.'
          config_param :ignore_error_log_interval, :time, default: DEFAULT_IGNORE_ERROR_LOG_INTERVAL
        end
      end

      # Suppresses the repeated log for the same key within the interval.
      # Shared by filter/out_prometheus (keyed by metric name) and in_prometheus
      # (keyed by an error scope). Each plugin owns its own instance, since the
      # lifetime differs; only the implementation is shared. The granularity is
      # absorbed by the key, and an optional fingerprint lets a caller emit
      # immediately when the content changes (e.g. a different error).
      class LogThrottle
        Entry = Struct.new(:time, :fingerprint, :suppressed)

        def initialize(interval)
          @interval = interval
          @mutex = Mutex.new
          # bounded by the number of keys (metrics / scopes), so it never grows
          # unexpectedly
          @entries = {}
        end

        # Returns [emit?, suppressed_count]. It emits (returns true) when the key
        # is seen for the first time, when the fingerprint changes, or when the
        # interval has elapsed. suppressed_count is how many logs were dropped
        # for the same fingerprint since the last emission.
        def check(key, fingerprint = nil)
          return [true, 0] if @interval <= 0

          @mutex.synchronize do
            now = Fluent::Clock.now
            last = @entries[key]
            if last.nil? || last.fingerprint != fingerprint || (now - last.time) >= @interval
              suppressed = (last && last.fingerprint == fingerprint) ? last.suppressed : 0
              @entries[key] = Entry.new(now, fingerprint, 0)
              [true, suppressed]
            else
              last.suppressed += 1
              [false, 0]
            end
          end
        end
      end

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

      def self.parse_metrics_elements(conf, registry, labels = {}, opts = {})
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
            metrics << Fluent::Plugin::Prometheus::Summary.new(element, registry, labels, opts)
          when 'gauge'
            metrics << Fluent::Plugin::Prometheus::Gauge.new(element, registry, labels, opts)
          when 'counter'
            metrics << Fluent::Plugin::Prometheus::Counter.new(element, registry, labels, opts)
          when 'histogram'
            metrics << Fluent::Plugin::Prometheus::Histogram.new(element, registry, labels, opts)
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
        @label_set_limit_log_throttle = Fluent::Plugin::Prometheus::LogThrottle.new(@ignore_error_log_interval)
        @dropped_label_sets_counter = nil
      end

      def metric_options
        {
          max_label_value_length: @max_label_value_length,
          max_series_per_metric: @max_series_per_metric,
        }
      end

      # Registered on the first drop only, so that a plugin which never drops a
      # label set does not expose a metric which stays 0 forever. Its only label
      # is the metric name, which comes from the configuration and not from a
      # record, so this metric cannot blow up the cardinality by itself.
      def dropped_label_sets_counter
        @dropped_label_sets_counter ||=
          begin
            @registry.counter(DROPPED_LABEL_SETS_METRIC_NAME,
                              docstring: DROPPED_LABEL_SETS_METRIC_DESC,
                              labels: [:name])
          rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
            # another plugin instance shares the registry and registered it first
            Fluent::Plugin::Prometheus::Metric.get(@registry, DROPPED_LABEL_SETS_METRIC_NAME,
                                                   :counter, DROPPED_LABEL_SETS_METRIC_DESC)
          end
      end

      def warn_label_set_limit(metric)
        # the drop is always counted, while the log below is throttled
        dropped_label_sets_counter.increment(labels: { name: metric.name.to_s })

        emit, suppressed = @label_set_limit_log_throttle.check(metric.name)
        return unless emit

        if suppressed > 0
          log.warn "prometheus: dropped a label set because the metric reached max_series_per_metric.",
                   name: metric.name, max_series_per_metric: metric.max_series_per_metric,
                   suppressed_log_count: suppressed
        else
          log.warn "prometheus: dropped a label set because the metric reached max_series_per_metric.",
                   name: metric.name, max_series_per_metric: metric.max_series_per_metric
        end
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
          rescue Fluent::Plugin::Prometheus::LabelSetLimitError
            # dropping the label set is intended, so it is not an error event
            warn_label_set_limit(metric)
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
            rescue Fluent::Plugin::Prometheus::LabelSetLimitError
              # dropping the label set is intended, so it is not an error event
              warn_label_set_limit(metric)
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
        attr_reader :max_label_value_length
        attr_reader :max_series_per_metric

        def initialize(element, registry, labels, opts = {})
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

          # <metric> can narrow down the limits given by the plugin
          @max_label_value_length = metric_limit(element, 'max_label_value_length',
                                                 opts.fetch(:max_label_value_length, DEFAULT_MAX_LABEL_VALUE_LENGTH))
          @max_series_per_metric = metric_limit(element, 'max_series_per_metric',
                                                opts.fetch(:max_series_per_metric, DEFAULT_MAX_SERIES_PER_METRIC))
          @series = {}
          @series_mutex = Mutex.new

          if @initialized
            @base_initlabels = Fluent::Plugin::Prometheus.parse_initlabels_elements(element, @base_labels)
            # the pre-initialized label sets consume the limit as well, and the
            # client already holds them, so they are established right away
            @base_initlabels.each do |initlabels|
              @series[normalize_label_set(initlabels)] = :confirmed
            end
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
              label[k] = truncate_label_value(expander.expand(v))
            else
              label[k] = truncate_label_value(v.call(record))
            end
          end
          label
        end

        # Instruments a record through the given block and keeps its label set
        # as a series once the client holds it. A record which fails to be
        # instrumented (e.g. its value is not a number) gives its slot back,
        # since such records must not exhaust max_series_per_metric and make
        # the following valid label sets dropped. A label set which a
        # concurrent call gave to the client in the meantime keeps its slot.
        def with_label_set(record, expander)
          label = labels(record, expander)
          # The slot is taken before instrumenting and given back on failure,
          # instead of being taken afterwards: two threads which build a new
          # label set at the same time would otherwise both pass the check and
          # let the client create more series than max_series_per_metric.
          reserved = reserve_series!(label)
          begin
            result = yield label
          rescue
            # only the call which took the slot may give it back: a concurrent
            # call which joined an already reserved label set has nothing of
            # its own to release
            release_series(label) if reserved
            raise
          end
          # the client holds the label set now, whether this call reserved it
          # or joined a reservation made by a concurrent one
          confirm_series(label)
          result
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

        private

        def metric_limit(element, name, default)
          return default unless element.has_key?(name)

          begin
            # base 10 explicitly, so that a value like 08 is not an octal
            Integer(element[name], 10)
          rescue ArgumentError, TypeError
            raise ConfigError, "#{name} in <metric> must be an integer: #{element[name]}"
          end
        end

        def truncate_label_value(value)
          # a RecordAccessor may return a value which is not a String
          value = value.to_s unless value.is_a?(String)
          return value if @max_label_value_length <= 0

          value.length > @max_label_value_length ? value[0, @max_label_value_length] : value
        end

        def normalize_label_set(label)
          label.each_with_object({}) do |(k, v), normalized|
            normalized[k] = truncate_label_value(v)
          end
        end

        # Keeps the cardinality of a metric bounded. Once the limit is reached,
        # the already known label sets keep working and only a new one is
        # refused. Checking the limit and taking the slot happen under the same
        # lock, so that concurrent calls cannot both take the last one.
        # A slot is taken as :reserved until the instrumentation confirms it,
        # so that a failing call can tell an in-flight reservation from a
        # series the client already holds.
        # Returns true when this call took the slot, which is what tells
        # #with_label_set whether it has something to give back on failure.
        def reserve_series!(label)
          return false if @max_series_per_metric <= 0

          @series_mutex.synchronize do
            next false if @series.key?(label)

            if @series.size >= @max_series_per_metric
              # the message must not contain the label set, it comes from a record
              raise LabelSetLimitError, "#{@name} reached max_series_per_metric (#{@max_series_per_metric})"
            end

            @series[label] = :reserved
            next true
          end
        end

        # Marks a label set as established, once the client actually holds it.
        # The slot is (re)taken without checking the limit on purpose: the
        # series exists on the client side already, so it has to be accounted
        # for even when a concurrent failure gave the reservation back in the
        # meantime.
        def confirm_series(label)
          return if @max_series_per_metric <= 0

          @series_mutex.synchronize do
            @series[label] = :confirmed
          end
        end

        # Gives a reserved slot back when the instrumentation failed, so that a
        # record which never reached the client does not consume the limit. A
        # label set which a concurrent call confirmed in the meantime is kept:
        # the client holds that series, and dropping it here would let the
        # metric grow past max_series_per_metric.
        def release_series(label)
          @series_mutex.synchronize do
            @series.delete(label) if @series[label] == :reserved
          end
        end
      end

      class Gauge < Metric
        def initialize(element, registry, labels, opts = {})
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
            with_label_set(record, expander) do |label|
              @gauge.set(value, labels: label)
            end
          end
        end
      end

      class Counter < Metric
        def initialize(element, registry, labels, opts = {})
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

          with_label_set(record, expander) do |label|
            @counter.increment(by: value, labels: label)
          end
        end
      end

      class Summary < Metric
        def initialize(element, registry, labels, opts = {})
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
            with_label_set(record, expander) do |label|
              @summary.observe(value, labels: label)
            end
          end
        end
      end

      class Histogram < Metric
        def initialize(element, registry, labels, opts = {})
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
            with_label_set(record, expander) do |label|
              @histogram.observe(value, labels: label)
            end
          end
        end
      end
    end
  end
end
