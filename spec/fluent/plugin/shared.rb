
BASE_CONFIG = %[
  type prometheus
]

SIMPLE_CONFIG = BASE_CONFIG + %[
  type prometheus
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
  <labels>
    test_key test_value
  </labels>
]

shared_examples_for 'output configuration' do
  context 'base config' do
    let(:config) { BASE_CONFIG }
    it 'does not raise error' do
      expect{driver}.not_to raise_error
    end
  end

  context 'simple config' do
    let(:config) { SIMPLE_CONFIG }
    it 'does not raise error' do
      expect{driver}.not_to raise_error
    end
  end

  context 'full config' do
    let(:config) { FULL_CONFIG }
    it 'does not raise error' do
      expect{driver}.not_to raise_error
    end
  end

  context 'unknown type' do
    let(:config) { BASE_CONFIG + %[
<metric>
  type foo
</metric>
] }
    it 'raises ConfigError' do
      expect{driver}.to raise_error Fluent::ConfigError
    end
  end
end
