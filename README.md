# fluent-plugin-prometheus, a plugin for [Fluentd](http://fluentd.org)

[![Build Status](https://travis-ci.org/kazegusuri/fluent-plugin-prometheus.svg?branch=master)](https://travis-ci.org/kazegusuri/fluent-plugin-prometheus)

TODO

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

TODO

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
