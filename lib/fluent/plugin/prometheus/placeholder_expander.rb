module Fluent
  module Plugin
    module Prometheus
      class ExpandBuilder
        # ${tag}, ${tag_parts[...]}, ${tag_prefix[...]} and ${tag_suffix[...]}
        # must be built from the tag only.
        TAG_DERIVED_PLACEHOLDER = /\A\$\{tag(_parts|_prefix|_suffix)?(\[[^\]]*\])?\}\z/.freeze

        def self.build(placeholder, log:)
          new(log: log).build(placeholder)
        end

        def initialize(log:)
          @log = log
        end

        def build(placeholder_values)
          placeholders = {}
          tag_placeholders = {}
          placeholder_values.each do |key, value|
            case value
            when Array
              size = value.size
              value.each_with_index do |v, i|
                placeholders["${#{key}[#{i}]}"] = v
                placeholders["${#{key}[#{i - size}]}"] = v
              end
            when Hash
              value.each do |k, v|
                placeholders[%(${#{key}["#{k}"]})] = v
              end
            else
              if key == 'tag'
                tag_placeholders = build_tag(value)
              else
                placeholders["${#{key}}"] = value
              end
            end
          end

          # A record may have an array named "tag_parts", or a key named
          # "tag_parts[0]". Both make the same placeholder as the tag does.
          # merge! is not enough here, because a record can also use an index
          # which build_tag does not make, such as ${tag_parts[3]} for a tag
          # of 3 parts, or ${tag_prefix[-1]}. So remove them first, then such
          # a placeholder stays unknown.
          placeholders.delete_if { |k, _| TAG_DERIVED_PLACEHOLDER.match?(k) }
          placeholders.merge!(tag_placeholders)

          Fluent::Plugin::Prometheus::ExpandBuilder::PlaceholderExpander.new(@log, placeholders)
        end

        private

        def build_tag(tag)
          tags = tag.split('.')

          placeholders = { '${tag}' => tag }

          size = tags.size

          tags.each_with_index do |v, i|
            placeholders["${tag_parts[#{i}]}"] = v
            placeholders["${tag_parts[#{i - size}]}"] = v
          end

          tag_prefix(tags).each_with_index do |v, i|
            placeholders["${tag_prefix[#{i}]}"] = v
          end

          tag_suffix(tags).each_with_index do |v, i|
            placeholders["${tag_suffix[#{i}]}"] = v
          end

          placeholders
        end

        def tag_prefix(tags)
          tags = tags.dup
          return [] if tags.empty?

          ret = [tags.shift]
          tags.each.with_index(1) do |tag, i|
            ret[i] = "#{ret[i-1]}.#{tag}"
          end
          ret
        end

        def tag_suffix(tags)
          return [] if tags.empty?

          tags = tags.dup.reverse
          ret = [tags.shift]
          tags.each.with_index(1) do |tag, i|
            ret[i] = "#{tag}.#{ret[i-1]}"
          end
          ret
        end

        class PlaceholderExpander
          PLACEHOLDER_REGEX = /(\${[^\[}]+(\[[^\]]+\])?})/.freeze

          attr_reader :placeholder

          def initialize(log, placeholder)
            @placeholder = placeholder
            @log = log
            @expander_cache = {}
          end

          def merge_placeholder(placeholder)
            @placeholder.merge!(placeholder)
          end

          def expand(str, dynamic_placeholders: nil)
            expander = if dynamic_placeholders
                         if @expander_cache[dynamic_placeholders]
                           @expander_cache[dynamic_placeholders]
                         else
                           e = ExpandBuilder.build(dynamic_placeholders, log: @log)
                           e.merge_placeholder(@placeholder)
                           @expander_cache[dynamic_placeholders] = e
                           e
                         end
                       else
                         self
                       end

            expander.expand!(str)
          end

          protected

          def expand!(str)
            str.gsub(PLACEHOLDER_REGEX) { |value|
              @placeholder.fetch(value) do
                @log.warn("unknown placeholder `#{value}` found")
                value # return as it is
              end
            }
          end
        end
      end
    end
  end
end
