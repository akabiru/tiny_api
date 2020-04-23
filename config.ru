# frozen_string_literal: true

app =
  proc do |env|
    qs = env['QUERY_STRING']
    number = Integer(qs.match(/number=(\d+)/)[1])

    [
      '200',
      { 'Content-Type' => 'text/plain' },
      [number.even? ? 'even' : 'odd']
    ]
  end

# Simplified Key value store
# @api private
#
module DataStore
  attr_reader :data

  def initialize(defaults = {})
    @data = defaults
  end

  def read(key)
    data[key]
  end

  def write(key, value)
    data[key] = value
  end
end

require 'uri'
require 'socket'

# A straightforward HTTP client implemented specially for this article to
# allow us to focus only on the differences between code powered by threads
# and code powered by fibers
#
# @see https://github.com/alexbrahastoll/ad-hoc-http
#
class AdHocHTTP
  attr_reader :uri, :socket, :read_buffer

  DEFAULT_HEADERS = {
    'User-Agent' => 'AdHocHTTP',
    'Accept' => '*/*',
    'Connection' => 'close'
  }.freeze

  def initialize(uri)
    @uri = URI.parse(uri)
    @socket = nil
    @read_buffer = ''
  end

  def blocking_get
    host = uri.host
    port = uri.port

    address = Socket.getaddrinfo(host, nil, Socket::AF_INET).first[3]
    socket_address = Socket.pack_sockaddr_in(port, address)
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    socket.connect(socket_address)

    http_msg = "GET #{uri.request_uri} HTTP/1.1\r\n"
    DEFAULT_HEADERS.each do |header, value|
      http_msg += "#{header}: #{value}\r\n"
    end
    http_msg += "\r\n"
    socket.write(http_msg)
    parse_response(socket.read)
  ensure
    socket&.close
  end

  def init_non_blocking_get
    @socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

    socket
  end

  def connect_non_blocking_get
    host = uri.host
    port = uri.port
    address = Socket.getaddrinfo(host, nil, Socket::AF_INET).first[3]
    socket_address = Socket.pack_sockaddr_in(port, address)

    socket.connect_nonblock(socket_address, exception: false)
  end

  def write_non_blocking_get
    http_msg = "GET #{uri.request_uri} HTTP/1.1\r\n"
    DEFAULT_HEADERS.each do |header, value|
      http_msg += "#{header}: #{value}\r\n"
    end
    http_msg += "\r\n"
    socket.write_nonblock(http_msg, exception: false)
  end

  def read_non_blocking_get
    parse_partial_response(socket.read_nonblock(65_536, exception: false))
  end

  def close_non_blocking_get
    socket&.close
  end

  def parse_partial_response(response)
    return :wait_readable if response == :wait_readable

    unless response.nil?
      read_buffer << response
      return :wait_readable
    end

    parse_response(read_buffer)
  end

  def parse_response(response)
    status = response.match(%r{HTTP/1\.1 (\d{3})}i)[1]
    body = response.match(/(?:\r\n){2}(.*)\z/im)[1]

    [status, body]
  end
end

# Concurrent client
#  * Concurrently fetches 1,000 records and stores them the datastore.
# @api private
#
class ThreadPoweredIntegration
  attr_reader :ds

  def initialize
    @ds = Datastore.new(even: 0, odd: 0)
  end

  def handle_response(status, body)
    return if status != '200'

    key = body.to_sym
    curr_count = ds.read(key)
    ds.write(key, curr_count + 1)
  end

  def run
    threads = []

    (1..1000).each_slice(250) do |subset|
      threads << Thread.new do
        subset.each do |number|
          begin
            uri_str = "http://localhost:9292/even_or_odd?number=#{number}"
            status, body = AdHocHTTP.new(uri_str).blocking_get
            handle_response(status, body)
          rescue StandardError => e
            warn(e)
            retry
          end
        end
      end
    end

    threads.each(&:join)
  end
end

run app
