# The default Prometheus client data store has no means of removing values.
# For the "retention" feature we need to be able to remove metrics with specific labels after some time of inactivity.
# By patching the Metric class and using our own DataStore we implement that missing feature.
module Prometheus
  module Client
    class Metric
      def remove(labels)
        label_set = label_set_for(labels)
        @store.remove(labels: label_set)
      end
    end
  end
end

module Fluent
  module Plugin
    module Prometheus
      # Stores all the data in simple hashes, one per metric. Each of these metrics
      # synchronizes access to their hash, but multiple metrics can run observations
      # concurrently.
      class DataStore
        class InvalidStoreSettingsError < StandardError; end

        def for_metric(metric_name, metric_type:, metric_settings: {})
          # We don't need `metric_type` or `metric_settings` for this particular store
          validate_metric_settings(metric_settings: metric_settings)
          MetricStore.new
        end

        private

        def validate_metric_settings(metric_settings:)
          unless metric_settings.empty?
            raise InvalidStoreSettingsError,
                  "Synchronized doesn't allow any metric_settings"
          end
        end

        class MetricStore
          def initialize
            @internal_store = Hash.new { |hash, key| hash[key] = 0.0 }
            @lock = Monitor.new
          end

          def synchronize
            @lock.synchronize { yield }
          end

          def set(labels:, val:)
            synchronize do
              @internal_store[labels] = val.to_f
            end
          end

          def increment(labels:, by: 1)
            synchronize do
              @internal_store[labels] += by
            end
          end

          def get(labels:)
            synchronize do
              @internal_store[labels]
            end
          end

          def remove(labels:)
            synchronize do
              @internal_store.delete(labels)
            end
          end

          def all_values
            synchronize { @internal_store.dup }
          end
        end

        private_constant :MetricStore
      end
    end
  end
end
