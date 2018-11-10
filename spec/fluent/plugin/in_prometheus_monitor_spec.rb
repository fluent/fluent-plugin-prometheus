require 'spec_helper'
require 'fluent/plugin/in_prometheus_monitor'
require 'fluent/test/driver/input'

describe Fluent::Plugin::PrometheusMonitorInput do
  MONITOR_CONFIG = %[
  @type prometheus_monitor
  <labels>
    host ${hostname}
    foo bar
    no_effect1 $.foo.bar
    no_effect2 $[0][1]
  </labels>
]

  let(:config) { MONITOR_CONFIG }
  let(:port) { 24231 }
  let(:driver) { Fluent::Test::Driver::Input.new(Fluent::Plugin::PrometheusMonitorInput).configure(config) }

  describe '#configure' do
    it 'does not raise error' do
      expect{driver}.not_to raise_error
    end
  end
end
