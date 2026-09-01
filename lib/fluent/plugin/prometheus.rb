require 'prometheus/client'
require 'prometheus/client/formats/text'
require 'fluent/plugin/prometheus/log_throttle'
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
      class LabelSetLimitError < StandardError; end

      # 0 or less means unlimited. The limit is unlimited by default, because
      # enabling it changes the existing metrics silently: dropping a label set
      # loses the record without any way to recover it. An operator who needs
      # to bound the cardinality has to opt in explicitly.
      DEFAULT_MAX_SERIES_PER_METRIC = 0
      DEFAULT_IGNORE_ERROR_LOG_INTERVAL = 3600

      # the drops are visible in Prometheus, not only in the Fluentd log
      DROPPED_LABEL_SETS_METRIC_NAME = :fluentd_prometheus_dropped_label_sets_total
      DROPPED_LABEL_SETS_METRIC_DESC = 'The total number of records dropped because the metric reached max_series_per_metric.'

      def self.included(klass)
        klass.class_eval do
          desc 'The maximum number of label sets a metric can hold. Exceeding label sets are dropped. 0 (default) means unlimited.'
          config_param :max_series_per_metric, :integer, default: DEFAULT_MAX_SERIES_PER_METRIC
          desc 'The interval to suppress the repeated warning about the drops.'
          config_param :ignore_error_log_interval, :time, default: DEFAULT_IGNORE_ERROR_LOG_INTERVAL
        end
      end

      # The label sets a client metric holds. The client registry keys its
      # metrics by name alone, so every <metric> section with the same name
      # instruments the same client metric and shares this set, instead of
      # holding max_series_per_metric label sets of its own.
      class SeriesSet
        # The set is kept on the client metric, so that it is found again by
        # every section. The registry does not drop its metrics, so the set is
        # still there after a reload.
        IVAR = :@fluent_plugin_prometheus_series_set

        # Sections are built at configuration time, which is single threaded,
        # so this needs no lock.
        def self.of(client_metric)
          client_metric.instance_variable_get(IVAR) ||
            client_metric.instance_variable_set(IVAR, new)
        end

        def initialize
          @series = {}
          @mutex = Mutex.new
        end

        # Only <initlabels> come from the configuration. Counting a label set
        # a record brought would refuse a good configuration after a reload.
        def initial_size
          @mutex.synchronize { @series.count { |_, state| state == :initial } }
        end

        # Checking the limit and taking the slot happen under the same lock, so
        # that concurrent calls cannot both take the last one. The slot stays
        # :reserved until the instrumentation confirms it, so that a failing
        # call can tell an in-flight reservation from a series the client holds.
        def reserve(label, limit, name)
          @mutex.synchronize do
            next false if @series.key?(label)

            if @series.size >= limit
              raise LabelSetLimitError, "#{name} reached max_series_per_metric (#{limit})"
            end

            @series[label] = :reserved
            next true
          end
        end

        # Marks a label set as established, once the client actually holds it.
        # The limit is not checked on purpose: the series exists on the client
        # side already, so it has to be accounted for even when a concurrent
        # failure gave the reservation back in the meantime.
        def confirm(label)
          @mutex.synchronize do
            # #initial_size has to keep counting it, so a record on it does not
            # change where it came from
            next if @series[label] == :initial

            @series[label] = :confirmed
          end
        end

        # The limit is not checked here either: a section which cannot hold
        # these label sets is refused when the configuration is read.
        def confirm_initial(label)
          @mutex.synchronize { @series[label] = :initial }
        end

        # Gives a reserved slot back when the instrumentation failed, so that a
        # label set the client does not hold does not consume the limit. One
        # which a concurrent call confirmed in the meantime is kept: the client
        # holds that series.
        def release(label)
          @mutex.synchronize { @series.delete(label) if @series[label] == :reserved }
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

        # <metric> sections with the same name share one client
        # metric. All of their <initlabels> label sets are known only
        # after every section is built, so the check runs here and not
        # in the constructor not to depend on the order of the
        # sections.
        metrics.each(&:check_series_limit!)

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
          max_series_per_metric: @max_series_per_metric,
        }
      end

      # Registered on the first occurrence only, so that a plugin which never
      # drops anything does not expose a counter which stays 0 forever. Its
      # labels come from the configuration, so they cannot blow up on their own.
      def limit_counter(name, docstring, labels)
        @registry.counter(name, docstring: docstring, labels: labels)
      rescue ::Prometheus::Client::Registry::AlreadyRegisteredError
        # another plugin instance shares the registry and registered it first
        Fluent::Plugin::Prometheus::Metric.get(@registry, name, :counter, docstring)
      end

      def dropped_label_sets_counter
        @dropped_label_sets_counter ||=
          limit_counter(DROPPED_LABEL_SETS_METRIC_NAME, DROPPED_LABEL_SETS_METRIC_DESC, [:name])
      end

      def warn_label_set_limit(metric)
        # the drop is always counted, while the log below is throttled
        dropped_label_sets_counter.increment(labels: { name: metric.name.to_s })

        warn_throttled(@label_set_limit_log_throttle, metric.name,
                       "prometheus: dropped a label set because the metric reached max_series_per_metric.",
                       name: metric.name, max_series_per_metric: metric.max_series_per_metric)
      end

      # The counter above is never throttled, only the log which comes with it:
      # one line per record would flood the Fluentd log, and the count is in
      # Prometheus already.
      def warn_throttled(throttle, key, message, **details)
        emit, suppressed = throttle.check(key)
        return unless emit

        details = details.merge(suppressed_log_count: suppressed) if suppressed > 0
        log.warn(message, details)
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

          # <metric> overrides the limit given by the plugin
          @max_series_per_metric = metric_limit(element, 'max_series_per_metric',
                                                opts.fetch(:max_series_per_metric, DEFAULT_MAX_SERIES_PER_METRIC))

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
              label[k] = normalize_label_value(v.call(record))
            end
          end
          label
        end

        # Instruments a record through the given block and keeps its label set
        # as a series once the client holds it. The slot is taken before
        # instrumenting and given back when the client refused the record, so
        # that a label set the client does not hold does not exhaust
        # max_series_per_metric.
        def with_label_set(record, expander)
          label = labels(record, expander)
          reserved = reserve_series!(label)
          begin
            result = yield label
          rescue
            # a call which joined another's reservation has nothing to release
            release_series(label) if reserved
            raise
          end
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

        # <initlabels> label sets go to the client as soon as the
        # configuration is read. Every <metric> section with the same name
        # shares them, so reject a section which has no room for the label
        # sets.
        def check_series_limit!
          return if @max_series_per_metric <= 0
          # two <initlabels> blocks with the same values make one label set
          held = @series_set.initial_size
          return if held <= @max_series_per_metric

          raise ConfigError, "metric #{@name} already holds #{held} label sets from <initlabels>, " \
                             "shared by every <metric> section with this name, " \
                             "but max_series_per_metric is #{@max_series_per_metric} in this section: " \
                             "the limit is already exceeded before any record arrives"
        end

        private

        # The client refuses a value which is not a number, but it is only
        # called once the label set has been reserved, and Summary refuses it
        # only once it has already incremented its count: releasing the slot
        # does not take that half instrumented series back from the client.
        # Refuse the value before it reaches either.
        def validate_value!(value)
          return if value.is_a?(Numeric)

          raise ArgumentError, 'value must be a number'
        end

        def metric_limit(element, name, default)
          return default unless element.has_key?(name)

          begin
            # base 10 explicitly, so that a value like 08 is not an octal
            Integer(element[name], 10)
          rescue ArgumentError, TypeError
            raise ConfigError, "#{name} in <metric> must be an integer: #{element[name]}"
          end
        end

        # Called by a subclass, once it has its client metric.
        def bind_series_set(client_metric)
          @series_set = SeriesSet.of(client_metric)

          return unless @initialized

          # The client gets them even when this section has no limit, so they
          # take their slots in both cases. A section with the same name shares
          # this set and has to see them. Their number is fixed by the
          # configuration. Counting them cannot leak like the label sets that
          # records bring.
          @base_initlabels.each do |initlabels|
            @series_set.confirm_initial(normalize_label_set(initlabels))
          end
        end

        # The SeriesSet keys a label set by its values, so the same value has to
        # look the same whether a RecordAccessor or <initlabels> produced it.
        def normalize_label_value(value)
          value.is_a?(String) ? value : value.to_s
        end

        def normalize_label_set(label)
          label.each_with_object({}) do |(k, v), normalized|
            normalized[k] = normalize_label_value(v)
          end
        end

        # Returns true when this call took the slot, which tells #with_label_set
        # whether it has something to give back on failure.
        def reserve_series!(label)
          # If the limit is off, a label set from a record is not counted.
          # If it is counted, the set grows with every new label set and
          # uses too much memory.
          return false if @max_series_per_metric <= 0

          @series_set.reserve(label, @max_series_per_metric, @name)
        end

        def confirm_series(label)
          return if @max_series_per_metric <= 0

          @series_set.confirm(label)
        end

        def release_series(label)
          return if @max_series_per_metric <= 0

          @series_set.release(label)
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
          bind_series_set(@gauge)

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
            validate_value!(value)
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
          bind_series_set(@counter)

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

          validate_value!(value)
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
          bind_series_set(@summary)

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
            validate_value!(value)
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
          bind_series_set(@histogram)

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
            validate_value!(value)
            with_label_set(record, expander) do |label|
              @histogram.observe(value, labels: label)
            end
          end
        end
      end
    end
  end
end
