$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'fluent/test'
require 'fluent/plugin/prometheus'

# Disable Test::Unit
module Test::Unit::RunCount; def run(*); end; end

Fluent::Test.setup
