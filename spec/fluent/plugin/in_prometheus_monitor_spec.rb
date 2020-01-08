require 'spec_helper'
require 'fluent/plugin/in_prometheus_monitor'
require 'fluent/test/driver/input'

describe Fluent::Plugin::PrometheusMonitorInput do
  MONITOR_CONFIG = %[
  @type prometheus_monitor
  <labels>
    host ${hostname}
    foo bar
  </labels>
]

  INVALID_MONITOR_CONFIG = %[
  @type prometheus_monitor

  <labels>
    host ${hostname}
    foo bar
    invalid_use1 $.foo.bar
    invalid_use2 $[0][1]
  </labels>
]

  let(:config) { MONITOR_CONFIG }
  let(:driver) { Fluent::Test::Driver::Input.new(Fluent::Plugin::PrometheusMonitorInput).configure(config) }

  describe '#configure' do
    describe 'valid' do
      it 'does not raise error' do
        expect{driver}.not_to raise_error
      end
    end

    describe 'invalid' do
      let(:config) { INVALID_MONITOR_CONFIG }
      it 'expect raise error' do
        expect{driver}.to raise_error
      end
    end
  end
end
