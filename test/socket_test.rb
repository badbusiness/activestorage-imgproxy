# frozen_string_literal: true

require "test_helper"
require "socket"
require "tmpdir"

# WebMock cannot answer the question these tests ask. Its `to_timeout` raises
# inside the adapter and never reaches Net::HTTP's own retry loop, so a test
# built on it stays green even when every request is silently made twice.
# These run against a real TCPServer, with WebMock out of the way.
class SocketTest < Minitest::Test
  include ImgproxyTestHelper

  RESIZE = { resize_to_limit: [ 100, 100 ], format: :png }.freeze

  def setup
    super
    @connections = 0
    @mutex = Mutex.new
    # allow_net_connect! would leave WebMock's Net::HTTP adapter installed, and
    # that adapter reimplements the transport -- so settings that live on the
    # real Net::HTTP (ignore_eof, max_retries) would silently have no effect
    # and these tests would prove nothing. It has to be out of the way entirely.
    WebMock.disable!
  end

  def teardown
    # First, and before anything that can raise: leaving WebMock disabled would
    # let every later test in the suite reach the network for real.
    WebMock.enable!
    WebMock.disable_net_connect!
    @acceptor&.kill
    @server&.close
    super
  end

  # Net::HTTP retries idempotent requests once by itself (max_retries defaults
  # to 1, and Net::ReadTimeout is on its retry list), so a hung imgproxy used to
  # cost two full read timeouts and hold the thread for twice as long.
  def test_a_hung_imgproxy_costs_one_timeout_and_one_connection
    serve { |socket| read_request(socket); sleep 5 }
    ActiveStorage::Imgproxy.config.timeout = 1

    elapsed = measure { user_with_avatar.avatar.variant(**RESIZE).processed }

    assert_equal 1, connections, "a timeout must not be retried, by us or by Net::HTTP"
    assert_operator elapsed, :<, 1.7, "one read timeout (1s), not two"
  end

  # The counter-proof: a connection that dies before sending anything *is*
  # retried, exactly once -- by this gem, not twice over by Net::HTTP as well.
  def test_a_reset_before_any_bytes_is_retried_exactly_once
    serve do |socket|
      read_request(socket)
      socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [ 1, 0 ].pack("ii"))
    end

    user_with_avatar.avatar.variant(**RESIZE).processed

    assert_equal 2, connections, "one retry, so two connections"
  end

  # Net::HTTP#ignore_eof defaults to true, so a body that stops short of its
  # Content-Length comes back looking complete. Combined with a variant being
  # written once and never regenerated, that stored a half image forever.
  def test_a_body_that_stops_short_of_its_content_length_falls_back
    body = ImgproxyTestHelper::TRANSFORMED_PNG
    serve do |socket|
      read_request(socket)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: #{body.bytesize}\r\n\r\n")
      # A *clean* close, not a reset: this is the case Net::HTTP hands back as
      # a complete response when ignore_eof is left at its default.
      socket.write(body.byteslice(0, 30))
    end

    before = Dir.glob(File.join(Dir.tmpdir, "ActiveStorage-imgproxy-*")).size
    variant = user_with_avatar.avatar.variant(**RESIZE).processed

    refute_equal 30, variant.download.bytesize, "a truncated body must never become the variant"
    assert_operator variant.download.bytesize, :>, 100, "expected the vips fallback"
    assert_equal 2, connections, "a truncated body is retried once"
    assert_equal before, Dir.glob(File.join(Dir.tmpdir, "ActiveStorage-imgproxy-*")).size, "tempfile leaked"
  end

  # A peer that closes cleanly before sending any headers raises EOFError, not
  # ECONNRESET. Without EOFError on the retriable list this would not be
  # retried at all, which is what makes that entry load-bearing.
  def test_a_clean_close_before_the_headers_is_retried_once
    serve { |socket| read_request(socket) } # the ensure in #serve closes it

    user_with_avatar.avatar.variant(**RESIZE).processed

    assert_equal 2, connections, "an EOF before the headers is retried once"
  end

  def test_a_real_socket_serves_the_variant
    request = nil
    serve { |socket| request = read_request(socket); write_png(socket) }

    assert_equal ImgproxyTestHelper::TRANSFORMED_PNG,
      user_with_avatar.avatar.variant(**RESIZE).processed.download
    assert_equal 1, connections

    # Net::HTTP asks for gzip unless told otherwise, and then inflates the body
    # while Content-Length still describes the compressed one -- which would
    # make the length check fail on every gzip response.
    assert_match(/^accept-encoding: identity\r$/i, request)
    refute_match(/gzip/i, request)
  end

  private
    attr_reader :server

    def connections
      @mutex.synchronize { @connections }
    end

    def serve(&handler)
      @server = TCPServer.new("127.0.0.1", 0)
      ActiveStorage::Imgproxy.config.url = "http://127.0.0.1:#{@server.addr[1]}"

      @acceptor = Thread.new do
        loop do
          socket = @server.accept
          @mutex.synchronize { @connections += 1 }
          Thread.new(socket) do |s|
            begin
              handler.call(s)
            rescue StandardError
              nil
            ensure
              s.close
            end
          end
        end
      end
    end

    def read_request(socket)
      request = +""
      request << socket.readpartial(4096) until request.include?("\r\n\r\n")
      request
    end

    def write_png(socket)
      body = ImgproxyTestHelper::TRANSFORMED_PNG
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
      socket.write(body)
    end

    def measure
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
end
