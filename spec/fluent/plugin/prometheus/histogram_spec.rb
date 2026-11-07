require 'spec_helper'

describe Fluent::Plugin::Prometheus::Histogram do
  let(:registry) { ::Prometheus::Client::Registry.new }

  def build_histogram(buckets)
    element = Fluent::Config::Element.new(
      'metric', '',
      {
        'name' => 'histogram_buckets',
        'type' => 'histogram',
        'desc' => 'Something foo.',
        'key' => 'foo',
        'buckets' => buckets,
      },
      []
    )
    Fluent::Plugin::Prometheus::Histogram.new(element, registry, {}, {})
  end

  def buckets_of(buckets)
    build_histogram(buckets)
    registry.get(:histogram_buckets).buckets
  end

  it 'keeps integer and decimal buckets' do
    expect(buckets_of('0.1, 1, 5, 10')).to eql([0.1, 1, 5, 10])
  end

  it 'keeps buckets of three or more digits as floats, as before' do
    expect(buckets_of('10, 100, 1000')).to eql([10, 100.0, 1000.0])
  end

  it 'keeps signed integer buckets as integers' do
    expect(buckets_of('-5, 0, +5')).to eql([-5, 0, 5])
  end

  it 'parses decimal buckets without a leading zero' do
    expect(buckets_of('.005, .01, .025')).to eql([0.005, 0.01, 0.025])
  end

  it 'parses buckets in exponent notation' do
    expect(buckets_of('1e-3, 1e-2, 1.5e2')).to eql([0.001, 0.01, 150.0])
  end

  it 'refuses a bucket which is not a number' do
    expect { build_histogram('0.1, abc') }
      .to raise_error(Fluent::ConfigError, /buckets in <metric> histogram_buckets must be numbers/)
  end
end
