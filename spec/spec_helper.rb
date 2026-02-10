$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'fluent/test'
require 'fluent/test/helpers'
require 'fluent/plugin/prometheus'

# Disable Test::Unit
Test::Unit::AutoRunner.need_auto_run = false

Fluent::Test.setup
include Fluent::Test::Helpers

def ipv6_enabled?
  require 'socket'

  begin
    # Try to actually bind to an IPv6 address to verify it works
    sock = Socket.new(Socket::AF_INET6, Socket::SOCK_STREAM, 0)
    sock.bind(Socket.sockaddr_in(0, '::1'))
    sock.close
    
    # Also test that we can resolve IPv6 addresses
    # This is needed because some systems can bind but can't connect
    Socket.getaddrinfo('::1', nil, Socket::AF_INET6)
    true
  rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT, SocketError
    false
  end
end
