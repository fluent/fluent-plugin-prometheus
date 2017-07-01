$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/plugin/prometheus'

# Disable Test::Unit
Test::Unit::AutoRunner.need_auto_run = false

Fluent::Test.setup
include Fluent::Test::Helpers
