# fluent-plugin-prometheus, a plugin for [Fluentd](http://fluentd.org)

[![Build Status](https://travis-ci.org/kazegusuri/fluent-plugin-prometheus.svg?branch=master)](https://travis-ci.org/kazegusuri/fluent-plugin-prometheus)

A fluent plugin that instruments metrics from records and exposes them via web interface. Intended to be used together with a [Prometheus server](https://github.com/prometheus/prometheus).

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

fluentd-plugin-prometheus includes 4 plugins.

- `prometheus` input plugin
- `prometheus_monitor` input plugin
- `prometheus` output plugin
- `prometheus` filter plugin

See [sample configuration](./misc/fluentd-sample.conf), or try [tutorial](#try-plugin-with-nginx).

### prometheus input plugin

You have to configure this plugin to expose metrics collected by other promtheus plugins.
This plugin provides a metrics HTTP endpoint to be scraped by a prometheus server on 24231/tcp(default).

With following configuration, you can access http://localhost:24231/metrics on a server where fluentd running.

```
<source>
  type prometheus
</source>
```

### prometheus_monitor input plugin

This plugin collects internal metrics in Fluentd. The metrics are similar to/part of [monitor_agent](http://docs.fluentd.org/articles/monitoring#monitoring-agent).

Current exposed metrics:

- `buffere_queue_length` of each BufferedOutput plugins
- `buffer_total_queued_size` of each BufferedOutput plugins
- `retry_count` of each BufferedOutput plugins

With following configuration, those metrics are collected.

<source>
  type prometheus_monitor
</source>

### prometheus output/filter plugin

Both output/filter plugins instrument metrics from records. Both plugins have no impact against values of each records, just read.

Assuming you have following configuration and receiving message,

```
<match message>
  type stdout
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
  type prometheus
  <metric>
    name message_foo_counter
    type counter
    desc The total number of foo in message.
    key foo
  </metric>
</filter>

<match message>
  type stdout
</match>
```

In output plugin style:

```
<filter message>
  type prometheus
  <metric>
    name message_foo_counter
    type counter
    desc The total number of foo in message.
    key foo
  </metric>
</filter>

<match message>
  type copy
  <store>
    type prometheus
    <metric>
      name message_foo_counter
      type counter
      desc The total number of foo in message.
      key foo
    </metric>
  </store>
  <store>
    type stdout
  </store>
</match>
```

With above configuration, the plugin collects a metric named `message_foo_counter` from key `foo` of each records.

## Supported Metric Types

For details of each metric type, see [Prometheus documentation](http://prometheus.io/docs/concepts/metric_types/). Also see [metric name guide](http://prometheus.io/docs/practices/naming/).

#### counter type

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
- `<labels>`: additional labels for this metric (optional)

#### gauge type

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
- `<labels>`: additional labels for this metric (optional)

#### summary type

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
- `<labels>`: additional labels for this metric (optional)

## Try plugin with nginx

Checkout respotiroy and setup it.

```
$ git clone git://github.com/kazegusuri/fluent-plugin-prometheus
$ cd fluent-plugin-prometheus
$ bundle install --path vendor/bundle
```

Download pre-compiled prometheus binary and start it. It listens on 9090.

```
$ mkdir prometheus
$ wget https://github.com/prometheus/prometheus/releases/download/0.13.3/prometheus-0.13.3.linux-amd64.tar.gz -O - | tar zxf - -C prometheus
$ ./prometheus/prometheus -config.file=./misc/prometheus.conf -storage.local.path=./prometheus/metrics
```

Install Nginx for sample metrics. It listens on 80 and 9999.

```
$ sudo apt-get install -y nginx
$ sudo cp misc/nginx_proxy.conf /etc/nginx/sites-enabled/proxy
$ sudo chmod 777 /var/log/nginx && sudo chmod +r /var/log/nginx/access.log
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

1. Fork it ( https://github.com/kazegusuri/fluent-plugin-prometheus/fork )
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
    <td>License</td><td>MIT License</td>
  </tr>
</table>
