# fluent-plugin-prometheus, a plugin for [Fluentd](https://www.fluentd.org)

[![linux](https://github.com/fluent/fluent-plugin-prometheus/actions/workflows/linux.yml/badge.svg)](https://github.com/fluent/fluent-plugin-prometheus/actions/workflows/linux.yml)

A fluent plugin that instruments metrics from records and exposes them via web interface. Intended to be used together with a [Prometheus server](https://github.com/prometheus/prometheus).

## Requirements

| fluent-plugin-prometheus | fluentd    | ruby   |
|--------------------------|------------|--------|
| 1.x.y                    | >= v1.9.1  | >= 2.4 |
| 1.[0-7].y                | >= v0.14.8 | >= 2.1 |
| 0.x.y                    | >= v0.12.0 | >= 1.9 |

Since v1.8.0, fluent-plugin-prometheus uses [http_server helper](https://docs.fluentd.org/plugin-helper-overview/api-plugin-helper-http_server) to launch HTTP server.
If you want to handle lots of connections, install `async-http` gem.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fluent-plugin-prometheus'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fluent-plugin-prometheus

## Usage

fluentd-plugin-prometheus includes 6 plugins.

- `prometheus` input plugin
- `prometheus_monitor` input plugin
- `prometheus_output_monitor` input plugin
- `prometheus_tail_monitor` input plugin
- `prometheus` output plugin
- `prometheus` filter plugin

See [sample configuration](./misc/fluentd_sample.conf), or try [tutorial](#try-plugin-with-nginx).

### prometheus input plugin

You have to configure this plugin to expose metrics collected by other Prometheus plugins.
This plugin provides a metrics HTTP endpoint to be scraped by a Prometheus server on 24231/tcp(default).

With following configuration, you can access http://localhost:24231/metrics on a server where fluentd running.

```
<source>
  @type prometheus
</source>
```

More configuration parameters:

- `bind`: binding interface (default: '127.0.0.1')
- `port`: listen port (default: 24231)
- `metrics_path`: metrics HTTP endpoint (default: /metrics)
- `aggregated_metrics_path`: metrics HTTP endpoint (default: /aggregated_metrics)
- `content_encoding`: encoding format for the exposed metrics (default: identity). Supported formats are {identity, gzip}
- `ignore_error_log_interval`: Suppress repeated error logs in a certain period of time or until message was changed (default: 1h)

When using multiple workers, each worker binds to port + `fluent_worker_id`.
To scrape metrics from all workers at once, you can access http://localhost:24231/aggregated_metrics.

#### TLS setting

Use `<trasnport tls>`. See [transport config article](https://docs.fluentd.org/configuration/transport-section) for more details.

```
<source>
  @type prometheus
  <transport tls>
    # TLS parameters...
  </transport
</source>
```

### prometheus_monitor input plugin

This plugin collects internal metrics in Fluentd. The metrics are similar to/part of [monitor_agent](https://docs.fluentd.org/input/monitor_agent).


#### Exposed metrics

- `fluentd_status_buffer_queue_length`
- `fluentd_status_buffer_total_bytes`
- `fluentd_status_retry_count`
- `fluentd_status_buffer_newest_timekey` from fluentd v1.4.2
- `fluentd_status_buffer_oldest_timekey` from fluentd v1.4.2

#### Configuration

With following configuration, those metrics are collected.

```
<source>
  @type prometheus_monitor
</source>
```

More configuration parameters:

- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `interval`: interval to update monitor_agent information in seconds (default: 5)

### prometheus_output_monitor input plugin

This plugin collects internal metrics for output plugin in Fluentd. This is similar to `prometheus_monitor` plugin, but specialized for output plugin. There are Many metrics `prometheus_monitor` does not include, such as `num_errors`, `retry_wait` and so on.

#### Exposed metrics

Metrics for output

- `fluentd_output_status_retry_count`
- `fluentd_output_status_num_errors`
- `fluentd_output_status_emit_count`
- `fluentd_output_status_retry_wait`
    - current retry_wait computed from last retry time and next retry time
- `fluentd_output_status_emit_records`
- `fluentd_output_status_write_count`
- `fluentd_output_status_rollback_count`
- `fluentd_output_status_flush_time_count` in milliseconds from fluentd v1.6.0
- `fluentd_output_status_slow_flush_count` from fluentd v1.6.0

Metrics for buffer

- `fluentd_output_status_buffer_total_bytes`
- `fluentd_output_status_buffer_stage_length` from fluentd v1.6.0
- `fluentd_output_status_buffer_stage_byte_size` from fluentd v1.6.0
- `fluentd_output_status_buffer_queue_length`
- `fluentd_output_status_buffer_queue_byte_size` from fluentd v1.6.0
- `fluentd_output_status_buffer_newest_timekey` from fluentd v1.6.0
- `fluentd_output_status_buffer_oldest_timekey` from fluentd v1.6.0
- `fluentd_output_status_buffer_available_space_ratio` from fluentd v1.6.0

#### Configuration

With following configuration, those metrics are collected.

```
<source>
  @type prometheus_output_monitor
</source>
```

More configuration parameters:

- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `interval`: interval to update monitor_agent information in seconds (default: 5)
- `gauge_all`: Specify metric type. If `true`, use `gauge` type. If `false`, use `counter` type. Since v2, this parameter will be removed and use `counter` type.

### prometheus_tail_monitor input plugin

This plugin collects internal metrics for in_tail plugin in Fluentd. in_tail plugin holds internal state for files that the plugin is watching. The state is sometimes important to monitor plugins work correctly.

This plugin uses internal class of Fluentd, so it's easy to break.

#### Exposed metrics

- `fluentd_tail_file_position`: Current bytes which plugin reads from the file
- `fluentd_tail_file_inode`: inode of the file
- `fluentd_tail_file_closed`: Number of closed files
- `fluentd_tail_file_opened`: Number of opened files
- `fluentd_tail_file_rotated`: Number of rotated files
- `fluentd_tail_file_throttled`: Number of times files got throttled (only with fluentd version > 1.17)

Default labels:

- `plugin_id`: a value set for a plugin in configuration.
- `type`: plugin name. `in_tail` only for now.
- `path`: file path

#### Configuration

With following configuration, those metrics are collected.

```
<source>
  @type prometheus_tail_monitor
</source>
```

More configuration parameters:

- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `interval`: interval to update monitor_agent information in seconds (default: 5)

### prometheus output/filter plugin

Both output/filter plugins instrument metrics from records. Both plugins have no impact against values of each records, just read.

Assuming you have following configuration and receiving message,

```
<match message>
  @type stdout
</match>
```

```
message {
  "foo": 100,
  "bar": 200,
  "baz": 300
}
```

In filter plugin style,

```
<filter message>
  @type prometheus
  <metric>
    name message_foo_counter
    type counter
    desc The total number of foo in message.
    key foo
  </metric>
</filter>

<match message>
  @type stdout
</match>
```

In output plugin style:

```
<filter message>
  @type prometheus
  <metric>
    name message_foo_counter
    type counter
    desc The total number of foo in message.
    key foo
  </metric>
</filter>

<match message>
  @type copy
  <store>
    @type prometheus
    <metric>
      name message_foo_counter
      type counter
      desc The total number of foo in message.
      key foo
    </metric>
  </store>
  <store>
    @type stdout
  </store>
</match>
```

With above configuration, the plugin collects a metric named `message_foo_counter` from key `foo` of each records.

You can access nested keys in records via dot or bracket notation (https://docs.fluentd.org/plugin-helper-overview/api-plugin-helper-record_accessor#syntax), for example: `$.kubernetes.namespace`, `$['key1'][0]['key2']`. The record accessor is enable only if the value starts with `$.` or `$[`.

See Supported Metric Type and Labels for more configuration parameters.

#### Limiting label expansion

Label values come from records, so a metric grows unboundedly when a label is
bound to a field with many distinct values. Both plugins can bound it with
`max_series_per_metric`: once a metric holds that many label sets, a record
which brings a new one is dropped, while the label sets already known keep
being instrumented.

|parameter|description|default|
|---|---|---|
|max_series_per_metric|The maximum number of label sets a metric can hold. `0` means unlimited.|0|
|ignore_error_log_interval|The interval in seconds to suppress the repeated warning about the drops. `0` logs every occurrence.|3600|

**The limit is disabled by default and must be enabled explicitly**, since a
dropped record is lost and cannot be recovered. A `<metric>` section overrides
the value given to the plugin, so that a metric which expands faster than the
others is bound on its own, while one whose labels are known to be bounded
stays unlimited with `0`:

```
<filter message>
  @type prometheus
  max_series_per_metric 1000
  <metric>
    name message_foo_counter
    type counter
    desc The total number of foo in message.
    key foo
    max_series_per_metric 10
    <labels>
      path $.kubernetes.pod_name
    </labels>
  </metric>
</filter>
```

The label sets are counted per metric name, not per `<metric>` section: sections
with the same `name`, in one plugin or in two, share one count. Each of them
refuses a new label set once that shared count reaches its own limit, so a
section which stays at `0` adds label sets without counting them. Its
`<initlabels>` are counted anyway. They come from the configuration and their
number is fixed. The metric holds them in every section.

The count is per worker process as well, since a worker has its own registry and
exposes the metrics it holds itself. With `workers N`, a metric can hold up to N
times `max_series_per_metric` label sets in total, so divide the number of label
sets the metric may reach by the number of workers.

A record which fails to be instrumented, for example when the value of `key` is
not a number, does not consume the limit. A pre-initialized label set
(`initialized` and `<initlabels>`) consumes it from the start, since the metric
holds it before any record arrives.

A `<metric>` section is refused at startup with a configuration error when the
`<initlabels>` label sets already fill its limit. The limit is exceeded before
any record arrives, and the section can never take a new label set.

These label sets are shared by every section with the same `name`. A section can
be refused because of another section:

```
<metric>
  name shared
  type counter
  desc Something foo.
  max_series_per_metric 2
  initialized true
  <labels>
    path $.path
  </labels>
  <initlabels>
    path /a
  </initlabels>
  <initlabels>
    path /b
  </initlabels>
</metric>
<metric>
  name shared               # the same name, so the 2 label sets count here too
  type counter
  desc Something foo.
  max_series_per_metric 1   # refused: 2 label sets do not fit into 1
  <labels>
    path $.path
  </labels>
</metric>
```

The second section is refused even though it declares no `<initlabels>` of its
own. The same happens when the first section sets `max_series_per_metric 0`.
The metric holds its label sets in both cases. A limit equal to their number is
fine because all label sets of the metric are known in advance.

The check runs after every `<metric>` section of a plugin is read. It does not
depend on the order of the sections. Sections that share a `name` across two
plugins are only checked against the sections read before them.

The check runs again when Fluentd reloads the configuration. It counts only the
label sets from `<initlabels>`. It does not count the label sets that records
brought, so the metric does not make the reload fail with the label sets it took
while it was running.

A reload does not clear the registry. The metric still holds the label sets from
the `<initlabels>` of the old configuration, and the check counts them too. So
it can refuse a new configuration which has fewer `<initlabels>` than the old
one. Restart the worker to drop them.

##### Observing what the limit leaves out

A dropped label set is not routed to `@ERROR`, because it is what the
configuration asks for. It is reported in two ways instead:

* a warning in the Fluentd log, throttled per metric: it is suppressed for
  `ignore_error_log_interval` seconds and reports how many warnings were
  suppressed in the meantime.
* `fluentd_prometheus_dropped_label_sets_total{name}`, which counts the records
  the metric `name` did not instrument. It is registered on the first drop, so
  it does not show up as long as nothing is dropped, and its label comes from
  the configuration and not from a record, so it cannot expand on its own.

Alert on the counter to notice that a metric is losing records:

```
rate(fluentd_prometheus_dropped_label_sets_total[5m]) > 0
```

## Supported Metric Types

For details of each metric type, see [Prometheus documentation](http://prometheus.io/docs/concepts/metric_types/). Also see [metric name guide](http://prometheus.io/docs/practices/naming/).

### counter type

```
<metric>
  name message_foo_counter
  type counter
  desc The total number of foo in message.
  key foo
  <labels>
    tag ${tag}
    host ${hostname}
    foo bar
  </labels>
</metric>
```

- `name`: metric name (required)
- `type`: metric type (required)
- `desc`: description of this metric (required)
- `key`: key name of record for instrumentation (**optional**)
- `initialized`: boolean controlling initilization of metric (**optional**). See [Metric initialization](#metric-initialization)
- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `<initlabels>`: labels to use for initialization of ReccordAccessors/Placeholder labels (**optional**). See [Metric initialization](#metric-initialization)

If key is empty, the metric values is treated as 1, so the counter increments by 1 on each record regardless of contents of the record.

### gauge type

```
<metric>
  name message_foo_gauge
  type gauge
  desc The total number of foo in message.
  key foo
  <labels>
    tag ${tag}
    host ${hostname}
    foo bar
  </labels>
</metric>
```

- `name`: metric name (required)
- `type`: metric type (required)
- `desc`: description of metric (required)
- `key`: key name of record for instrumentation (required)
- `initialized`: boolean controlling initilization of metric (**optional**). See [Metric initialization](#metric-initialization)
- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `<initlabels>`: labels to use for initialization of ReccordAccessors/Placeholder labels (**optional**). See [Metric initialization](#metric-initialization)

### summary type

```
<metric>
  name message_foo
  type summary
  desc The summary of foo in message.
  key foo
  <labels>
    tag ${tag}
    host ${hostname}
    foo bar
  </labels>
</metric>
```

- `name`: metric name (required)
- `type`: metric type (required)
- `desc`: description of metric (required)
- `key`: key name of record for instrumentation (required)
- `initialized`: boolean controlling initilization of metric (**optional**). See [Metric initialization](#metric-initialization)
- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `<initlabels>`: labels to use for initialization of ReccordAccessors/Placeholder labels (**optional**). See [Metric initialization](#metric-initialization)

### histogram type

```
<metric>
  name message_foo
  type histogram
  desc The histogram of foo in message.
  key foo
  buckets 0.1, 1, 5, 10
  <labels>
    tag ${tag}
    host ${hostname}
    foo bar
  </labels>
</metric>
```

- `name`: metric name (required)
- `type`: metric type (required)
- `desc`: description of metric (required)
- `key`: key name of record for instrumentation (required)
- `initialized`: boolean controlling initilization of metric (**optional**). See [Metric initialization](#metric-initialization)
- `buckets`: buckets of record for instrumentation (optional)
- `<labels>`: additional labels for this metric (optional). See [Labels](#labels)
- `<initlabels>`: labels to use for initialization of ReccordAccessors/Placeholder labels (**optional**). See [Metric initialization](#metric-initialization)

## Labels

See [Prometheus Data Model](http://prometheus.io/docs/concepts/data_model/) first.

You can add labels with static value or dynamic value from records. In `prometheus_monitor` input plugin, you can't use label value from records.

### labels section

```
<labels>
  key1 value1
  key2 value2
</labels>
```

All labels sections has same format. Each lines have key/value for label.

You can access nested fields in records via dot or bracket notation (https://docs.fluentd.org/plugin-helper-overview/api-plugin-helper-record_accessor#syntax), for example: `$.kubernetes.namespace`, `$['key1'][0]['key2']`. The record accessor is enable only if the value starts with `$.` or `$[`. Other values are handled as raw string as is and may be expanded by placeholder described later.

You can use placeholder for label values. The placeholders will be expanded from reserved values and records.
If you specify `${hostname}`, it will be expanded by value of a hostname where fluentd runs.
The placeholder for records is deprecated. Use record accessor syntax instead.

Reserved placeholders are:

- `${hostname}`: hostname
- `${worker_id}`: fluent worker id
- `${tag}`: tag name
  - only available in Prometheus output/filter plugin
- `${tag_parts[N]}` refers to the Nth part of the tag.
  - only available in Prometheus output/filter plugin
- `${tag_prefix[N]}` refers to the [0..N] part of the tag.
  - only available in Prometheus output/filter plugin
- `${tag_suffix[N]}` refers to the [`tagsize`-1-N..] part of the tag.
  - where `tagsize` is the size of tag which is splitted with `.` (when tag is `1.2.3`, then `tagsize` is 3)
  - only available in Prometheus output/filter plugin

### Metric initialization

You can configure if a metric should be initialized to its zero value before receiving any event. To do so you just need to specify `initialized true`.

```
<metric>
  name message_bar_counter
  type counter
  desc The total number of bar in message.
  key bar
  initialized true
  <labels>
    foo bar
  </labels>
</metric>
```

If your labels contains ReccordAccessors or Placeholders, you must use `<initlabels>` to specify the values your ReccordAccessors/Placeholders will take. This feature is useful only if your Placeholders/ReccordAccessors contain deterministic values. Initialization will create as many zero value metrics as `<initlabels>` blocks you defined.
Potential reserved placeholders `${hostname}` and `${worker_id}`, as well as static labels, are automatically added and should not be specified in `<initlabels>` configuration.

```
<metric>
  name message_bar_counter
  type counter
  desc The total number of bar in message.
  key bar
  initialized true
  <labels>
    key $.foo
    tag ${tag}
    foo bar
    worker_id ${worker_id}
  </labels>
  <initlabels>
    key foo1
    tag tag1
  </initlabels>
  <initlabels>
    key foo2
    tag tag2
  </initlabels>
</metric>
<labels>
  hostname ${hostname}
</labels>
```

### top-level labels and labels inside metric

Prometheus output/filter plugin can have multiple metric section. Top-level labels section specifies labels for all metrics. Labels section inside metric section specifies labels for the metric. Both are specified, labels are merged.

```
<filter message>
  @type prometheus
  <metric>
    name message_foo_counter
    type counter
    desc The total number of foo in message.
    key foo
    <labels>
      key foo
      data_type ${type}
    </labels>
  </metric>
  <metric>
    name message_bar_counter
    type counter
    desc The total number of bar in message.
    key bar
    <labels>
      key bar
    </labels>
  </metric>
  <labels>
    tag ${tag}
    hostname ${hostname}
  </labels>
</filter>
```

In this case, `message_foo_counter` has `tag`, `hostname`, `key` and `data_type` labels.


## Try plugin with nginx

Checkout repository and setup.

```
$ git clone git://github.com/fluent/fluent-plugin-prometheus.git
$ cd fluent-plugin-prometheus
$ bundle install --path vendor/bundle
```

Download pre-compiled Prometheus binary and start it. It listens on 9090.

```
$ wget https://github.com/prometheus/prometheus/releases/download/v1.5.2/prometheus-1.5.2.linux-amd64.tar.gz -O - | tar zxf -
$ ./prometheus-1.5.2.linux-amd64/prometheus -config.file=./misc/prometheus.yaml -storage.local.path=./prometheus/metrics
```

Install Nginx for sample metrics. It listens on 80 and 9999.

```
$ sudo apt-get install -y nginx
$ sudo cp misc/nginx_proxy.conf /etc/nginx/sites-enabled/proxy
$ sudo chmod 777 /var/log/nginx && sudo chmod +r /var/log/nginx/*.log
$ sudo service nginx restart
```

Start fluentd with sample configuration. It listens on 24231.

```
$ bundle exec fluentd -c misc/fluentd_sample.conf -v
```

Generate some records by accessing nginx.

```
$ curl http://localhost/
$ curl http://localhost:9999/
```

Confirm that some metrics are exported via Fluentd.

```
$ curl http://localhost:24231/metrics
```

Then, make a graph on Prometheus UI. http://localhost:9090/

## Contributing

1. Fork it ( https://github.com/fluent/fluent-plugin-prometheus/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request


## Copyright

<table>
  <tr>
    <td>Author</td><td>Masahiro Sano <sabottenda@gmail.com></td>
  </tr>
  <tr>
    <td>Copyright</td><td>Copyright (c) 2015- Masahiro Sano</td>
  </tr>
  <tr>
    <td>License</td><td>Apache License, Version 2.0</td>
  </tr>
</table>
