module Fluent::Plugin

  ##
  # PromMetricsAggregator aggregates multiples metrics exposed using Prometheus text-based format
  # see https://github.com/prometheus/docs/blob/master/content/docs/instrumenting/exposition_formats.md


  class PrometheusMetrics
    def initialize
      @comments = []
      @metrics = []
    end

    def to_string
      (@comments + @metrics).join("\n")
    end

    def add_comment(comment)
      @comments << comment
    end

    def add_metric_value(value)
      @metrics << value
    end

    attr_writer :comments, :metrics
  end

  class PromMetricsAggregator
    def initialize
      @metrics = {}
    end

    def get_metric_name_from_comment(line)
      tokens = line.split(' ')
      if ['HELP', 'TYPE'].include?(tokens[1])
        tokens[2]
      else
        ''
      end
    end

    def add_metrics(metrics)
      current_metric = ''
      new_metric = false
      lines = metrics.split("\n")
      for line in lines
        if line[0] == '#'
          # Metric comment (# TYPE, # HELP)
          parsed_metric = get_metric_name_from_comment(line)
          if parsed_metric != ''
            if parsed_metric != current_metric
              # Starting a new metric comment block
              new_metric = !@metrics.key?(parsed_metric)
              if new_metric
                @metrics[parsed_metric] = PrometheusMetrics.new()
              end
              current_metric = parsed_metric
            end

            if new_metric && parsed_metric == current_metric
              # New metric, inject comments (# TYPE, # HELP)
              @metrics[parsed_metric].add_comment(line)
            end
          end
        else
          # Metric value, simply append line
          @metrics[current_metric].add_metric_value(line)
        end
      end
    end

    def get_metrics
      @metrics.map{|k,v| v.to_string()}.join("\n") + (@metrics.length ? "\n" : "")
    end
  end
end
