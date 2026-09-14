# frozen_string_literal: true

require "net/http"
require "openssl"
require "tempfile"
require "uri"
require "zlib"

module ActiveStorage
  module Imgproxy
    # Fetches a transformed image from imgproxy over plain HTTP and streams it
    # straight to disk.
    #
    # Retry policy, on purpose a narrow one, and the only one in play: Net::HTTP
    # retries idempotent requests once *by itself* (max_retries defaults to 1,
    # and its retry list covers Net::ReadTimeout, IOError, EOFError and
    # ECONNRESET), which silently doubled everything below. #perform therefore
    # sets max_retries = 0 and this class does all the counting.
    #
    # * a refused/reset connection or an unresolvable host is retried once --
    #   imgproxy was not there, so nothing was done twice;
    # * a 5xx is retried once -- imgproxy answered, but not with an image;
    # * a *timeout* is never retried, so a hung imgproxy costs one read_timeout
    #   and not two. A timeout means imgproxy is probably still busy with the
    #   first request; asking again doubles the work on a service that is
    #   already struggling, and doubles the time this thread is held. Falling
    #   back to vips right away is both faster and kinder.
    # * a 4xx is never retried -- imgproxy will not change its mind about a
    #   malformed or forbidden request.
    #
    # Every failure raises RequestFailed, which the transformer turns into a
    # fallback.
    class Client
      RETRIABLE_STATUS = (500..599).freeze
      MAX_ATTEMPTS = 2

      # "imgproxy did not deliver a response": safe to ask once more, because a
      # GET is idempotent and the tempfile is truncated before the retry, so a
      # partial body cannot be mixed with a complete one. Timeouts are
      # deliberately absent.
      #
      # EOFError is here as well as ECONNRESET: whether a peer that goes away
      # surfaces as a reset or as an unexpected EOF depends on the platform and
      # on the timing, and both mean the same thing. Note that an EOF *after* a
      # partial body is retried too, so the transformation can be done twice by
      # imgproxy -- bounded at one extra attempt, and much cheaper than storing
      # a truncated image forever.
      RETRIABLE_ERRORS = [
        Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, EOFError, SocketError
      ].freeze

      # "imgproxy did not answer properly", but asking again would not help or
      # would cost more than it saves. Wrapped in RequestFailed on first sight.
      FATAL_ERRORS = [
        Timeout::Error, IOError, SystemCallError, Net::ProtocolError,
        Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
        OpenSSL::SSL::SSLError, Zlib::Error
      ].freeze

      # How much of the response is read back to check the file signature. 32
      # bytes is enough for an ISO-BMFF ftyp box with a handful of compatible
      # brands, which is the longest thing looked at here.
      HEADER_BYTES = 32

      # File signatures for every format Active Storage can be asked for. A
      # format that is *not* in here is refused: accepting it on the status code
      # alone is how an HTML error page ends up stored as a variant forever.
      JPEG = ->(header) { header.start_with?("\xFF\xD8\xFF".b) }
      TIFF = ->(header) { header.start_with?("II*\x00".b) || header.start_with?("MM\x00*".b) }

      # An ISO-BMFF file names one major brand and a list of compatible brands:
      # [size][ftyp][major][minor version][compatible...]. Real AVIF files in
      # the wild carry major brand "mif1" with "avif" among the compatible
      # brands, so all of them have to be looked at, not just the major one.
      BRANDS = ->(header) {
        return [] unless header[4, 4] == "ftyp".b

        ([ header[8, 4] ] + header[16..].to_s.scan(/.{4}/m)).compact
      }
      ISOBMFF = ->(wanted) { ->(header) { BRANDS.call(header).intersect?(wanted) } }

      MAGIC = {
        "png" => ->(header) { header.start_with?("\x89PNG\r\n\x1A\n".b) },
        "jpg" => JPEG,
        "jpeg" => JPEG,
        # Variation#format hands back the requested extension verbatim, and
        # .jfif in particular is what Windows and Chrome produce on save.
        "jfif" => JPEG,
        "jpe" => JPEG,
        "jif" => JPEG,
        "jfi" => JPEG,
        "gif" => ->(header) { header.start_with?("GIF8".b) },
        "webp" => ->(header) { header.start_with?("RIFF".b) && header[8, 4] == "WEBP".b },
        "avif" => ISOBMFF.call(%w[avif avis mif1 miaf].map(&:b)),
        "heic" => ISOBMFF.call(%w[heic heix hevc heim heis mif1 msf1].map(&:b)),
        "heif" => ISOBMFF.call(%w[heic heix hevc heim heis mif1 msf1].map(&:b)),
        "tif" => TIFF,
        "tiff" => TIFF,
        "bmp" => ->(header) { header.start_with?("BM".b) },
        "ico" => ->(header) { header.start_with?("\x00\x00\x01\x00".b) },
        "psd" => ->(header) { header.start_with?("8BPS".b) }
      }.freeze

      private_constant :JPEG, :TIFF, :BRANDS, :ISOBMFF, :MAGIC

      def initialize(config)
        @config = config
      end

      # Returns an open, rewound, binary Tempfile with the transformed image.
      # The tempfile is cleaned up here if anything goes wrong, so the caller
      # only ever has to deal with a usable file or an exception.
      def download(url, extension:)
        uri = URI.parse(url)
        tempfile = Tempfile.new([ "ActiveStorage-imgproxy-", ".#{extension}" ], binmode: true)

        succeeded = false

        begin
          get(uri, into: tempfile)
          tempfile.flush
          tempfile.rewind
          verify!(tempfile, extension: extension)
          succeeded = true
          tempfile
        ensure
          tempfile.close! unless succeeded
        end
      end

      private
        attr_reader :config

        def get(uri, into:)
          attempt = 0

          begin
            attempt += 1
            perform(uri, into: into)
          rescue *RETRIABLE_ERRORS, RetriableResponse => error
            retry if attempt < MAX_ATTEMPTS

            raise RequestFailed, "imgproxy request failed after #{attempt} attempts: #{error.message}"
          rescue *FATAL_ERRORS => error
            raise RequestFailed, "imgproxy request failed: #{error.class}: #{error.message}"
          end
        end

        def perform(uri, into:)
          # A retry re-uses the same tempfile, so drop whatever the failed
          # attempt managed to write before starting over.
          into.truncate(0)
          into.rewind

          # The explicit nil is the proxy address: Net::HTTP.new defaults it to
          # :ENV, which would route imgproxy traffic through whatever http_proxy
          # the app happens to have set for outbound calls. imgproxy is an
          # internal service; it is never behind the proxy.
          http = Net::HTTP.new(uri.host, uri.port, nil)
          http.use_ssl = uri.scheme == "https"
          # Net::HTTP's own retry would turn "one attempt" into two, doubling
          # both the work on imgproxy and the time this thread is held.
          http.max_retries = 0
          # Without this, a body that stops short of its Content-Length is
          # returned as if it were complete -- and a truncated image is stored
          # as the variant and never regenerated.
          http.ignore_eof = false
          http.open_timeout = config.open_timeout
          http.read_timeout = config.timeout
          http.write_timeout = config.timeout

          http.start do |session|
            session.request(get_request(uri)) do |response|
              stream(response, into: into, expected: check!(response))
            end
          end
        end

        # Net::HTTP asks for gzip by default and transparently inflates the
        # answer -- but Content-Length keeps describing the *compressed* body,
        # so the length check below would see a mismatch on every single gzip
        # response and fall back every single time, after paying for the
        # transformation. An image is already compressed; identity costs
        # nothing and keeps the byte count meaningful.
        def get_request(uri)
          request = Net::HTTP::Get.new(uri)
          request["accept-encoding"] = "identity"
          request
        end

        # Only the status code is ever reported. An imgproxy error body echoes
        # the source URL it was given, which is a presigned S3 URL or a signed
        # Disk URL -- credentials that have no business in a log line or in an
        # instrumentation payload.
        def check!(response)
          status = response.code.to_i

          raise RetriableResponse, "imgproxy responded #{status}" if RETRIABLE_STATUS.cover?(status)
          raise RequestFailed, "imgproxy responded #{status}" unless status == 200

          # Base 10 explicitly: Integer() would otherwise read "068" as an
          # invalid octal (nil) and "0x40" as 64.
          length = Integer(response["content-length"].to_s, 10, exception: false)
          too_large!(length) if length && length > config.max_bytes
          length
        end

        # ignore_eof = false already turns a short body into an EOFError, but
        # only when this code talks to a socket directly. Counting the bytes as
        # well keeps the guarantee when something sits in between (a test
        # adapter, a future connection pool) and hands back a complete-looking
        # response.
        def stream(response, into:, expected:)
          written = 0

          response.read_body do |chunk|
            written += chunk.bytesize
            too_large!(written) if written > config.max_bytes

            into.write(chunk)
          end

          return if expected.nil? || written == expected

          raise RetriableResponse, "imgproxy sent #{written} of #{expected} announced bytes"
        end

        # A 200 is not proof that imgproxy sent an image. An error page, an
        # IMGPROXY_FALLBACK_IMAGE, or a truncated body all arrive as a perfectly
        # normal 200 -- and whatever comes back is stored as *the* variant and
        # never regenerated, because ActiveStorage::Variant#processed? only asks
        # the service whether the key exists. So the bytes are checked before
        # they are handed over, and anything that is not the requested format
        # falls back to vips instead.
        def verify!(tempfile, extension:)
          size = tempfile.size
          raise RequestFailed, "imgproxy returned an empty response" if size.zero?

          matches = MAGIC[extension.to_s.downcase]
          if matches.nil?
            raise RequestFailed, "no file signature known for #{extension}, refusing to trust the response"
          end

          header = tempfile.read(HEADER_BYTES).to_s.b
          tempfile.rewind
          return if matches.call(header)

          # The body itself is never reported: an imgproxy error page echoes the
          # signed source URL it was handed.
          raise RequestFailed, "imgproxy returned #{size} bytes that are not a #{extension} image"
        end

        def too_large!(bytes)
          raise RequestFailed, "imgproxy response of #{bytes} bytes exceeds the #{config.max_bytes} byte limit"
        end

        class RetriableResponse < StandardError; end
        private_constant :RetriableResponse
    end
  end
end
