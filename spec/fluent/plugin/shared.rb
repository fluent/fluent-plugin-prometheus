
BASE_CONFIG = %[
  type prometheus
]

SIMPLE_CONFIG = BASE_CONFIG + %[
  <metric>
    name simple_foo
    type counter
    desc Something foo.
    key foo
  </metric>
]

FULL_CONFIG = BASE_CONFIG + %[
  <metric>
    name full_foo
    type counter
    desc Something foo.
    key foo
    <labels>
      key foo1
    </labels>
  </metric>
  <metric>
    name full_bar
    type gauge
    desc Something bar.
    key bar
    <labels>
      key foo2
    </labels>
  </metric>
  <metric>
    name full_baz
    type summary
    desc Something baz.
    key baz
    <labels>
      key foo3
    </labels>
  </metric>
  <metric>
    name full_qux
    type histogram
    desc Something qux.
    key qux
    buckets 0.1, 1, 5, 10
    <labels>
      key foo4
    </labels>
  </metric>
  <metric>
    name full_accessor1
    type summary
    desc Something with accessor.
    key $.foo
    <labels>
      key foo5
    </labels>
  </metric>
  <metric>
    name full_accessor2
    type counter
    desc Something with accessor.
    key $.foo
    <labels>
      key foo6
    </labels>
  </metric>
  <labels>
    test_key test_value
  </labels>
]

PLACEHOLDER_CONFIG = BASE_CONFIG + %[
  <metric>
    name placeholder_foo
    type counter
    desc Something foo.
    key foo
    <labels>
      foo ${foo}
    </labels>
  </metric>
  <labels>
    tag ${tag}
    hostname ${hostname}
  </labels>
]

ACCESSOR_CONFIG = BASE_CONFIG + %[
  <metric>
    name accessor_foo
    type counter
    desc Something foo.
    key foo
    <labels>
      foo $.foo
    </labels>
  </metric>
]

COUNTER_WITHOUT_KEY_CONFIG = BASE_CONFIG + %[
  <metric>
    name without_key_foo
    type counter
    desc Something foo.
  </metric>
]

shared_examples_for 'output configuration' do
  context 'base config' do
    let(:config) { BASE_CONFIG }
    it { expect { driver }.not_to raise_error }
  end

  context 'with simple configuration' do
    let(:config) { SIMPLE_CONFIG }
    it { expect { driver }.not_to raise_error }
  end

  context 'with full configuration' do
    let(:config) { FULL_CONFIG }
    it { expect { driver }.not_to raise_error }
  end

  context 'with placeholder configuration' do
    let(:config) { PLACEHOLDER_CONFIG }
    it { expect { driver }.not_to raise_error }
  end

  context 'with accessor configuration' do
    let(:config) {  ACCESSOR_CONFIG }
    it { expect { driver }.not_to raise_error }
  end

  describe 'with counter without key configuration' do
    let(:config) { COUNTER_WITHOUT_KEY_CONFIG }
    it { expect { driver }.not_to raise_error }
  end

  context 'with unknown type' do
    let(:config) do
      BASE_CONFIG + %[
      <metric>
        type foo
      </metric>
      ]
    end
    it { expect { driver }.to raise_error(Fluent::ConfigError) }
  end
end

shared_examples_for 'instruments record' do
  before do
    driver.run(default_tag: tag) { driver.feed(event_time, message) }
  end

  context 'full config' do
    let(:config) { FULL_CONFIG }
    let(:counter) { registry.get(:full_foo) }
    let(:gauge) { registry.get(:full_bar) }
    let(:summary) { registry.get(:full_baz) }
    let(:histogram) { registry.get(:full_qux) }
    let(:summary_with_accessor) { registry.get(:full_accessor1) }
    let(:counter_with_accessor) { registry.get(:full_accessor2) }

    it 'adds all metrics' do
      expect(registry.metrics.map(&:name)).to eq(%i[full_foo full_bar full_baz full_qux full_accessor1 full_accessor2])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)
      expect(gauge).to be_kind_of(::Prometheus::Client::Metric)
      expect(summary).to be_kind_of(::Prometheus::Client::Metric)
      expect(summary_with_accessor).to be_kind_of(::Prometheus::Client::Metric)
      expect(counter_with_accessor).to be_kind_of(::Prometheus::Client::Metric)
      expect(histogram).to be_kind_of(::Prometheus::Client::Metric)
    end

    it 'instruments counter metric' do
      expect(counter.type).to eq(:counter)
      expect(counter.get({test_key: 'test_value', key: 'foo1'})).to be_kind_of(Numeric)
      expect(counter_with_accessor.get({test_key: 'test_value', key: 'foo6'})).to be_kind_of(Numeric)
    end

    it 'instruments gauge metric' do
      expect(gauge.type).to eq(:gauge)
      expect(gauge.get({test_key: 'test_value', key: 'foo2'})).to eq(100)
    end

    it 'instruments summary metric' do
      expect(summary.type).to eq(:summary)
      expect(summary.get({test_key: 'test_value', key: 'foo3'})).to be_kind_of(Hash)
      expect(summary.get({test_key: 'test_value', key: 'foo3'})[0.99]).to eq(100)
      expect(summary_with_accessor.get({test_key: 'test_value', key: 'foo5'})[0.99]).to eq(100)
    end

    it 'instruments histogram metric' do
      driver.run(default_tag: tag) do
        4.times { driver.feed(event_time, message) }
      end

      expect(histogram.type).to eq(:histogram)
      expect(histogram.get({test_key: 'test_value', key: 'foo4'})).to be_kind_of(Hash)
      expect(histogram.get({test_key: 'test_value', key: 'foo4'})[10]).to eq(5) # 4 + `es` in before
    end
  end

  context 'placeholder config' do
    let(:config) { PLACEHOLDER_CONFIG }
    let(:counter) { registry.get(:placeholder_foo) }

    it 'expands placeholders with record values' do
      expect(registry.metrics.map(&:name)).to eq([:placeholder_foo])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)
      key, _ = counter.values.find {|k,v| v ==  100 }
      expect(key).to be_kind_of(Hash)
      expect(key[:tag]).to eq(tag)
      expect(key[:hostname]).to be_kind_of(String)
      expect(key[:hostname]).not_to eq("${hostname}")
      expect(key[:hostname]).not_to be_empty
      expect(key[:foo]).to eq("100")
    end
  end

  context 'accessor config' do
    let(:config) { ACCESSOR_CONFIG }
    let(:counter) { registry.get(:accessor_foo) }

    it 'expands accessor with record values' do
      expect(registry.metrics.map(&:name)).to eq([:accessor_foo])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)
      key, _ = counter.values.find {|k,v| v ==  100 }
      expect(key).to be_kind_of(Hash)
      expect(key[:foo]).to eq(100)
    end
  end

  context 'counter_without config' do
    let(:config) { COUNTER_WITHOUT_KEY_CONFIG }
    let(:counter) { registry.get(:without_key_foo) }

    it 'just increments by 1' do
      expect(registry.metrics.map(&:name)).to eq([:without_key_foo])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)
      _, value = counter.values.find {|k,v| k == {} }
      expect(value).to eq(1)
    end
  end
end
