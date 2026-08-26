require 'spec_helper'
require 'fluent/plugin/prometheus/log_throttle'

describe Fluent::Plugin::Prometheus::LogThrottle do
  # Fluent::Clock.now is monotonic, so a Hash is enough to fake it
  let(:clock) { { now: 1000.0 } }
  let(:interval) { 3600 }
  # in_prometheus builds it out of an error
  let(:fingerprint) { [RuntimeError, 'a'] }
  subject(:throttle) { described_class.new(interval) }

  before do
    allow(Fluent::Clock).to receive(:now) { clock[:now] }
  end

  describe '#check' do
    it 'emits on the first occurrence of a key' do
      emit, suppressed = throttle.check(:foo, fingerprint)
      expect(emit).to be true
      expect(suppressed).to eq(0)
    end

    it 'suppresses the same key within the interval' do
      throttle.check(:foo, fingerprint)
      clock[:now] += interval - 1
      emit, _ = throttle.check(:foo, fingerprint)
      expect(emit).to be false
    end

    it 'emits again once the interval has elapsed' do
      throttle.check(:foo, fingerprint)
      clock[:now] += interval
      emit, _ = throttle.check(:foo, fingerprint)
      expect(emit).to be true
    end

    it 'reports how many occurrences were suppressed in the meantime' do
      throttle.check(:foo, fingerprint)             # emits, suppressed=0
      2.times { throttle.check(:foo, fingerprint) } # suppressed 1, then 2
      clock[:now] += interval
      emit, suppressed = throttle.check(:foo, fingerprint)
      expect(emit).to be true
      expect(suppressed).to eq(2)
    end

    it 'resets the suppressed count after emitting' do
      throttle.check(:foo, fingerprint)
      2.times { throttle.check(:foo, fingerprint) }
      clock[:now] += interval
      throttle.check(:foo, fingerprint)             # emits with suppressed=2
      clock[:now] += interval
      _, suppressed = throttle.check(:foo, fingerprint)
      expect(suppressed).to eq(0)
    end

    it 'keeps a separate slot per key' do
      expect(throttle.check(:foo, fingerprint).first).to be true
      expect(throttle.check(:bar, fingerprint).first).to be true
    end

    # filter/out_prometheus throttles on the metric alone, since every drop of
    # a metric reads the same
    context 'without a fingerprint' do
      it 'throttles on the key alone' do
        expect(throttle.check(:foo).first).to be true
        expect(throttle.check(:foo).first).to be false
        expect(throttle.check(:bar).first).to be true
      end

      it 'reports how many occurrences were suppressed in the meantime' do
        throttle.check(:foo)
        2.times { throttle.check(:foo) }
        clock[:now] += interval
        emit, suppressed = throttle.check(:foo)
        expect(emit).to be true
        expect(suppressed).to eq(2)
      end
    end

    it 'emits immediately when the fingerprint changes within the interval' do
      expect(throttle.check(:foo, [RuntimeError, 'a']).first).to be true
      expect(throttle.check(:foo, [RuntimeError, 'b']).first).to be true
    end

    # the caller makes a new fingerprint for each event, so it has to be
    # compared by value, not by object identity
    it 'suppresses an equal fingerprint given as a different object' do
      expect(throttle.check(:foo, [RuntimeError, 'a']).first).to be true
      expect(throttle.check(:foo, [RuntimeError, 'a']).first).to be false
    end

    it 'does not carry the suppressed count across a fingerprint change' do
      throttle.check(:foo, [RuntimeError, 'a'])
      2.times { throttle.check(:foo, [RuntimeError, 'a']) }
      emit, suppressed = throttle.check(:foo, [RuntimeError, 'b'])
      expect(emit).to be true
      expect(suppressed).to eq(0)
    end

    context 'when interval is zero' do
      let(:interval) { 0 }

      it 'always emits without consulting the clock' do
        expect(Fluent::Clock).not_to receive(:now)
        3.times do
          emit, suppressed = throttle.check(:foo, fingerprint)
          expect(emit).to be true
          expect(suppressed).to eq(0)
        end
      end
    end

    context 'when interval is negative' do
      let(:interval) { -1 }

      it 'always emits' do
        expect(throttle.check(:foo, fingerprint).first).to be true
        expect(throttle.check(:foo, fingerprint).first).to be true
      end
    end

    it 'serializes concurrent checks for the same key into a single emission' do
      results = 10.times.map { Thread.new { throttle.check(:foo, fingerprint).first } }.map(&:value)
      expect(results.count(true)).to eq(1)
    end
  end
end
