#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'prometheus/client/push'
require 'fluent/plugin/output'

module Fluent::Plugin
  class PrometheusPushgatewayOutput < Fluent::Plugin::Output
    Fluent::Plugin.register_output('prometheus_pushgateway', self)

    helpers :timer

    desc 'The endpoint of pushgateway'
    config_param :gateway, :string, default: 'http://localhost:9091'
    desc 'job name. this value must be unique between instances'
    config_param :job_name, :string
    desc 'instance name'
    config_param :instance, :string, default: nil
    desc 'the interval of pushing data to pushgateway'
    config_param :push_interval, :time, default: 3

    def initialize
      super

      @registry = ::Prometheus::Client.registry
    end

    def multi_workers_ready?
      true
    end

    def configure(conf)
      super

      @push_client = ::Prometheus::Client::Push.new("#{@job_name}:#{fluentd_worker_id}", @instance, @gateway)
    end

    def start
      super

      timer_execute(:out_prometheus_pushgateway, @push_interval) do
        @push_client.add(@registry)
      end
    end

    def process(tag, es)
      # nothing
    end
  end
end
