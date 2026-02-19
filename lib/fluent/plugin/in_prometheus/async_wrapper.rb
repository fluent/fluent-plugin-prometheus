require 'async'

module Fluent::Plugin
  class PrometheusInput
    module AsyncWrapper
      def do_request(host:, port:, secure:)
        # Format host for URI - bracket IPv6 addresses if not already bracketed
        uri_host = if host.include?(':') && !host.start_with?('[')
                     "[#{host}]"
                   else
                     host
                   end
        
        endpoint =
          if secure
            context = OpenSSL::SSL::SSLContext.new
            context.verify_mode = OpenSSL::SSL::VERIFY_NONE
            Async::HTTP::Endpoint.parse("https://#{uri_host}:#{port}", ssl_context: context)
          else
            Async::HTTP::Endpoint.parse("http://#{uri_host}:#{port}")
          end

        Async::HTTP::Client.open(endpoint) do |client|
          yield(AsyncHttpWrapper.new(client))
        end
      end

      Response = Struct.new(:code, :body, :headers)

      class AsyncHttpWrapper
        def initialize(http)
          @http = http
        end

        def get(path)
          error = nil
          response = Async::Task.current.async {
            begin
              @http.get(path)
            rescue => e               # Async::Reactor rescue all error. handle it by itself
              error = e
            end
          }.wait

          if error
            raise error
          end

          Response.new(response.status.to_s, response.read || '', response.headers)
        end
      end
    end
  end
end
