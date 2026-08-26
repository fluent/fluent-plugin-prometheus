require 'fluent/clock'

module Fluent
  module Plugin
    module Prometheus
      # Suppresses the repeated log for the same key within the interval.
      # in_prometheus and filter/out_prometheus use it, each with its own
      # instance. The key decides what is throttled: an error scope or a
      # metric. When a fingerprint is given, a log whose fingerprint differs
      # from the last one is not suppressed.
      class LogThrottle
        Entry = Struct.new(:time, :fingerprint, :suppressed)

        def initialize(interval)
          @interval = interval
          @mutex = Mutex.new
          # one entry per key, so this does not grow without a limit
          @entries = {}
        end

        # Returns [emit, suppressed_count]. emit is true for the first log of a
        # key, for a new fingerprint, and after the interval has passed.
        # suppressed_count is how many logs were suppressed since the last one
        # was emitted. Without a fingerprint, a key is throttled by the
        # interval alone.
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
    end
  end
end
