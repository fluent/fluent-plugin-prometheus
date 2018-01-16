require 'spec_helper'
require 'fluent/plugin/in_prometheus'
require 'fluent/test/driver/input'

require 'net/http'

describe Fluent::Plugin::PromMetricsAggregator do

  metrics_worker_1 = %[# TYPE fluentd_status_buffer_queue_length gauge
# HELP fluentd_status_buffer_queue_length Current buffer queue length.
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="0",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="0",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
# TYPE fluentd_status_buffer_total_bytes gauge
# HELP fluentd_status_buffer_total_bytes Current total size of queued buffers.
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="0",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="0",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
# TYPE log_counter counter
# HELP log_counter the number of received logs
log_counter{worker_id="0",host="0123456789ab",tag="fluent.info"} 1.0
# HELP empty_metric A metric with no data
# TYPE empty_metric gauge
# HELP http_request_duration_seconds The HTTP request latencies in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.005"} 58
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.01"} 58
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.05"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.1"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="1"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="10"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="+Inf"} 59
http_request_duration_seconds_sum{code="200",worker_id="0",method="GET"} 0.05046115500000003
http_request_duration_seconds_count{code="200",worker_id="0",method="GET"} 59
]

  metrics_worker_2 = %[# TYPE fluentd_output_status_buffer_queue_length gauge
# HELP fluentd_output_status_buffer_queue_length Current buffer queue length.
fluentd_output_status_buffer_queue_length{host="0123456789ab",worker_id="0",plugin_id="plugin-1",type="s3"} 0.0
fluentd_output_status_buffer_queue_length{host="0123456789ab",worker_id="0",plugin_id="plugin-2",type="s3"} 0.0
# TYPE fluentd_output_status_buffer_total_bytes gauge
# HELP fluentd_output_status_buffer_total_bytes Current total size of queued buffers.
fluentd_output_status_buffer_total_bytes{host="0123456789ab",worker_id="0",plugin_id="plugin-1",type="s3"} 0.0
fluentd_output_status_buffer_total_bytes{host="0123456789ab",worker_id="0",plugin_id="plugin-2",type="s3"} 0.0
]

  metrics_worker_3 = %[# TYPE fluentd_status_buffer_queue_length gauge
# HELP fluentd_status_buffer_queue_length Current buffer queue length.
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="1",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="1",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
# TYPE fluentd_status_buffer_total_bytes gauge
# HELP fluentd_status_buffer_total_bytes Current total size of queued buffers.
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="1",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="1",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
# HELP http_request_duration_seconds The HTTP request latencies in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.005"} 70
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.01"} 70
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.05"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.1"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="1"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="10"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="+Inf"} 71
http_request_duration_seconds_sum{code="200",worker_id="1",method="GET"} 0.05646315600000003
http_request_duration_seconds_count{code="200",worker_id="1",method="GET"} 71
]

  metrics_merged_1_and_3 = %[# TYPE fluentd_status_buffer_queue_length gauge
# HELP fluentd_status_buffer_queue_length Current buffer queue length.
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="0",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="0",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="1",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_queue_length{host="0123456789ab",worker_id="1",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
# TYPE fluentd_status_buffer_total_bytes gauge
# HELP fluentd_status_buffer_total_bytes Current total size of queued buffers.
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="0",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="0",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="1",plugin_id="plugin-1",plugin_category="output",type="s3"} 0.0
fluentd_status_buffer_total_bytes{host="0123456789ab",worker_id="1",plugin_id="plugin-2",plugin_category="output",type="s3"} 0.0
# TYPE log_counter counter
# HELP log_counter the number of received logs
log_counter{worker_id="0",host="0123456789ab",tag="fluent.info"} 1.0
# HELP empty_metric A metric with no data
# TYPE empty_metric gauge
# HELP http_request_duration_seconds The HTTP request latencies in seconds.
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.005"} 58
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.01"} 58
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.05"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="0.1"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="1"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="10"} 59
http_request_duration_seconds_bucket{code="200",worker_id="0",method="GET",le="+Inf"} 59
http_request_duration_seconds_sum{code="200",worker_id="0",method="GET"} 0.05046115500000003
http_request_duration_seconds_count{code="200",worker_id="0",method="GET"} 59
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.005"} 70
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.01"} 70
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.05"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="0.1"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="1"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="10"} 71
http_request_duration_seconds_bucket{code="200",worker_id="1",method="GET",le="+Inf"} 71
http_request_duration_seconds_sum{code="200",worker_id="1",method="GET"} 0.05646315600000003
http_request_duration_seconds_count{code="200",worker_id="1",method="GET"} 71
]

  describe 'add_metrics' do
    context '1st_metrics' do
      it 'adds all fields' do
        all_metrics = Fluent::Plugin::PromMetricsAggregator.new
        all_metrics.add_metrics(metrics_worker_1)
        result_str = all_metrics.get_metrics

        expect(result_str).to eq(metrics_worker_1)
      end
    end
    context '2nd_metrics' do
      it 'append new metrics' do
        all_metrics = Fluent::Plugin::PromMetricsAggregator.new
        all_metrics.add_metrics(metrics_worker_1)
        all_metrics.add_metrics(metrics_worker_2)
        result_str = all_metrics.get_metrics

        expect(result_str).to eq(metrics_worker_1 + metrics_worker_2)
      end
    end

    context '3rd_metrics' do
      it 'append existing metrics in the right place' do
        all_metrics = Fluent::Plugin::PromMetricsAggregator.new
        all_metrics.add_metrics(metrics_worker_1)
        all_metrics.add_metrics(metrics_worker_2)
        all_metrics.add_metrics(metrics_worker_3)
        result_str = all_metrics.get_metrics

        expect(result_str).to eq(metrics_merged_1_and_3 + metrics_worker_2)
      end
    end
  end
end
