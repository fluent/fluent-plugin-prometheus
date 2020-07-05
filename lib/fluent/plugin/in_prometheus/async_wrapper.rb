require 'async'

module Fluent::Plugin
  class PrometheusInput
    module AsyncWrapper
      def do_request(host:, port:, secure:)
        endpoint =
          if secure
            context = OpenSSL::SSL::SSLContext.new
            context.verify_mode = OpenSSL::SSL::VERIFY_NONE
            Async::HTTP::Endpoint.parse("https://#{host}:#{port}", ssl_context: context)
          else
            Async::HTTP::Endpoint.parse("http://#{host}:#{port}")
          end

        client = Async::HTTP::Client.new(endpoint)
        yield(AsyncHttpWrapper.new(client))
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

          Response.new(response.status.to_s, response.body.read, response.headers)
        end
      end
    end
  end
end
