require 'spec_helper'

describe Fluent::Plugin::Prometheus::LogThrottle do
  # Fluent::Clock.now is monotonic, so a plain Hash is enough to drive it
  let(:clock) { { now: 1000.0 } }
  let(:interval) { 3600 }
  subject(:throttle) { described_class.new(interval) }

  before do
    allow(Fluent::Clock).to receive(:now) { clock[:now] }
  end

  describe '#check' do
    it 'emits on the first occurrence of a key' do
      emit, suppressed = throttle.check(:foo)
      expect(emit).to be true
      expect(suppressed).to eq(0)
    end

    it 'suppresses the same key within the interval' do
      throttle.check(:foo)
      clock[:now] += interval - 1
      emit, _ = throttle.check(:foo)
      expect(emit).to be false
    end

    it 'emits again once the interval has elapsed' do
      throttle.check(:foo)
      clock[:now] += interval
      emit, _ = throttle.check(:foo)
      expect(emit).to be true
    end

    it 'reports how many occurrences were suppressed in the meantime' do
      throttle.check(:foo)             # emits, suppressed=0
      2.times { throttle.check(:foo) } # suppressed 1, then 2
      clock[:now] += interval
      emit, suppressed = throttle.check(:foo)
      expect(emit).to be true
      expect(suppressed).to eq(2)
    end

    it 'resets the suppressed count after emitting' do
      throttle.check(:foo)
      2.times { throttle.check(:foo) }
      clock[:now] += interval
      throttle.check(:foo)             # emits with suppressed=2
      clock[:now] += interval
      _, suppressed = throttle.check(:foo)
      expect(suppressed).to eq(0)
    end

    it 'keeps a separate slot per key' do
      expect(throttle.check(:foo).first).to be true
      expect(throttle.check(:bar).first).to be true
    end

    context 'with a fingerprint' do
      it 'emits immediately when the fingerprint changes within the interval' do
        expect(throttle.check(:foo, [RuntimeError, 'a']).first).to be true
        expect(throttle.check(:foo, [RuntimeError, 'b']).first).to be true
      end

      # the caller builds a fresh fingerprint per event, so it must be compared
      # by value, not by identity
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
    end

    context 'when interval is zero' do
      let(:interval) { 0 }

      it 'always emits without consulting the clock' do
        expect(Fluent::Clock).not_to receive(:now)
        3.times do
          emit, suppressed = throttle.check(:foo)
          expect(emit).to be true
          expect(suppressed).to eq(0)
        end
      end
    end

    context 'when interval is negative' do
      let(:interval) { -1 }

      it 'always emits' do
        expect(throttle.check(:foo).first).to be true
        expect(throttle.check(:foo).first).to be true
      end
    end

    it 'serializes concurrent checks for the same key into a single emission' do
      results = 10.times.map { Thread.new { throttle.check(:foo).first } }.map(&:value)
      expect(results.count(true)).to eq(1)
    end
  end
end
