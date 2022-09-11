
BASE_CONFIG = %[
  @type prometheus
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
    initialized true
    <labels>
      key foo2
    </labels>
  </metric>
  <metric>
    name full_baz
    type summary
    desc Something baz.
    key baz
    initialized true
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
    initialized true
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
    desc Something with accessor
    key $.foo
    initialized true
    <labels>
      key foo6
    </labels>
  </metric>
  <metric>
    name full_accessor3
    type counter
    desc Something with accessor and several initialized metrics
    initialized true
    <labels>
      key $.foo
      key2 $.foo2
      key3 footix
    </labels>
    <initlabels>
      key foo6
      key2 foo7
    </initlabels>
    <initlabels>
      key foo8
      key2 foo9
    </initlabels>
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
    initialized true
    <labels>
      foo ${foo}
      foo2 foo2
    </labels>
    <initlabels>
      tag tag
      foo foo
    </initlabels>
  </metric>
  <labels>
    tag ${tag}
    hostname ${hostname}
    workerid ${worker_id}
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


  context 'with missing <initlabels>' do
    let(:config) do
      BASE_CONFIG + %[
      <metric>
        name simple_foo
        type counter
        desc Something foo but incorrect
        key foo
        initialized true
        <labels>
          key $.accessor
        </labels>
      </metric>
      ]
    end
    it { expect { driver }.to raise_error(Fluent::ConfigError) }
  end

  context 'with RecordAccessor set in <initlabels>' do
    let(:config) do
      BASE_CONFIG + %[
      <metric>
        name simple_foo
        type counter
        desc Something foo but incorrect
        key foo
        initialized true
        <labels>
          key $.accessor
        </labels>
        <initlabels>
          key $.accessor2
        <initlabels>
      </metric>
      ]
    end
    it { expect { driver }.to raise_error(Fluent::ConfigError) }
  end

  context 'with PlaceHolder set in <initlabels>' do
    let(:config) do
      BASE_CONFIG + %[
      <metric>
        name simple_foo
        type counter
        desc Something foo but incorrect
        key foo
        initialized true
        <labels>
          key ${foo}
        </labels>
        <initlabels>
          key ${foo}
        <initlabels>
      </metric>
      ]
    end
    it { expect { driver }.to raise_error(Fluent::ConfigError) }
  end

  context 'with non RecordAccessor label set in <initlabels>' do
    let(:config) do
      BASE_CONFIG + %[
      <metric>
        name simple_foo
        type counter
        desc Something foo but incorrect
        key foo
        initialized true
        <labels>
          key $.accessor
          key2 foo2
        </labels>
        <initlabels>
          key foo
          key2 foo2
        <initlabels>
      </metric>
      ]
    end
    it { expect { driver }.to raise_error(Fluent::ConfigError) }
  end

  context 'with non-matching label keys set in <initlabels>' do
    let(:config) do
      BASE_CONFIG + %[
      <metric>
        name simple_foo
        type counter
        desc Something foo but incorrect
        key foo
        initialized true
        <labels>
          key $.accessor
        </labels>
        <initlabels>
          key2 foo
        <initlabels>
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
    let(:counter_with_two_accessors) { registry.get(:full_accessor3) }

    it 'adds all metrics' do
      expect(registry.metrics.map(&:name)).to eq(%i[full_foo full_bar full_baz full_qux full_accessor1 full_accessor2 full_accessor3])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)
      expect(gauge).to be_kind_of(::Prometheus::Client::Metric)
      expect(summary).to be_kind_of(::Prometheus::Client::Metric)
      expect(summary_with_accessor).to be_kind_of(::Prometheus::Client::Metric)
      expect(counter_with_accessor).to be_kind_of(::Prometheus::Client::Metric)
      expect(counter_with_two_accessors).to be_kind_of(::Prometheus::Client::Metric)
      expect(histogram).to be_kind_of(::Prometheus::Client::Metric)
    end

    it 'instruments counter metric' do
      expect(counter.type).to eq(:counter)
      expect(counter.get(labels: {test_key: 'test_value', key: 'foo1'})).to be_kind_of(Numeric)
      expect(counter_with_accessor.get(labels: {test_key: 'test_value', key: 'foo6'})).to be_kind_of(Numeric)
      expect(counter_with_two_accessors.get(labels: {test_key: 'test_value', key: 'foo6', key2: 'foo7', key3: 'footix'})).to be_kind_of(Numeric)
    end

    it 'instruments gauge metric' do
      expect(gauge.type).to eq(:gauge)
      expect(gauge.get(labels: {test_key: 'test_value', key: 'foo2'})).to eq(100)
    end

    it 'instruments summary metric' do
      expect(summary.type).to eq(:summary)
      expect(summary.get(labels: {test_key: 'test_value', key: 'foo3'})).to be_kind_of(Hash)
      expect(summary_with_accessor.get(labels: {test_key: 'test_value', key: 'foo5'})["sum"]).to eq(100)
    end

    it 'instruments histogram metric' do
      driver.run(default_tag: tag) do
        4.times { driver.feed(event_time, message) }
      end

      expect(histogram.type).to eq(:histogram)
      expect(histogram.get(labels: {test_key: 'test_value', key: 'foo4'})).to be_kind_of(Hash)
      expect(histogram.get(labels: {test_key: 'test_value', key: 'foo4'})["10"]).to eq(5) # 4 + `es` in before
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
      expect(key[:foo]).to eq("100")
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

shared_examples_for 'initalized metrics' do
  before do
    driver.run(default_tag: tag)
  end

  context 'full config' do
    let(:config) { FULL_CONFIG }
    let(:counter) { registry.get(:full_foo) }
    let(:gauge) { registry.get(:full_bar) }
    let(:summary) { registry.get(:full_baz) }
    let(:histogram) { registry.get(:full_qux) }
    let(:summary_with_accessor) { registry.get(:full_accessor1) }
    let(:counter_with_accessor) { registry.get(:full_accessor2) }
    let(:counter_with_two_accessors) { registry.get(:full_accessor3) }
  
    it 'adds all metrics' do
      expect(registry.metrics.map(&:name)).to eq(%i[full_foo full_bar full_baz full_qux full_accessor1 full_accessor2 full_accessor3])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)
      expect(gauge).to be_kind_of(::Prometheus::Client::Metric)
      expect(summary).to be_kind_of(::Prometheus::Client::Metric)
      expect(summary_with_accessor).to be_kind_of(::Prometheus::Client::Metric)
      expect(counter_with_accessor).to be_kind_of(::Prometheus::Client::Metric)
      expect(counter_with_two_accessors).to be_kind_of(::Prometheus::Client::Metric)
      expect(histogram).to be_kind_of(::Prometheus::Client::Metric)
    end

    it 'tests uninitialized metrics' do
      expect(counter.values).to eq({})
      expect(summary_with_accessor.values).to eq({})
    end

    it 'tests initialized metrics' do
      expect(gauge.values).to eq({{:key=>"foo2", :test_key=>"test_value"}=>0.0})
      expect(summary.values).to eq({:key=>"foo3", :test_key=>"test_value"}=>{"count"=>0.0, "sum"=>0.0})
      expect(histogram.values).to eq({:key=>"foo4", :test_key=>"test_value"} => {"+Inf"=>0.0, "0.1"=>0.0, "1"=>0.0, "10"=>0.0, "5"=>0.0, "sum"=>0.0})
      expect(counter_with_accessor.values).to eq({{:key=>"foo6", :test_key=>"test_value"}=>0.0})
      expect(counter_with_two_accessors.values).to eq({{:key=>"foo6", :key2=>"foo7", :key3=>"footix", :test_key=>"test_value"}=>0.0, {:key=>"foo8", :key2=>"foo9", :key3=>"footix", :test_key=>"test_value"}=>0.0})
    end
  end

  context 'placeholder config' do
    let(:config) { PLACEHOLDER_CONFIG }
    let(:counter) { registry.get(:placeholder_foo) }

    it 'expands placeholders with record values' do
      expect(registry.metrics.map(&:name)).to eq([:placeholder_foo])
      expect(counter).to be_kind_of(::Prometheus::Client::Metric)

      key, _ = counter.values.find {|k,v| v ==  0.0 }
      expect(key).to be_kind_of(Hash)
      expect(key[:foo]).to eq("foo")
      expect(key[:foo2]).to eq("foo2")
      expect(key[:hostname]).to be_kind_of(String)
      expect(key[:hostname]).not_to eq("${hostname}")
      expect(key[:hostname]).not_to be_empty
      expect(key[:workerid]).to be_kind_of(String)
      expect(key[:workerid]).not_to eq("${worker_id}")
      expect(key[:workerid]).not_to be_empty
      expect(key[:tag]).to eq("tag")
    end
  end
end