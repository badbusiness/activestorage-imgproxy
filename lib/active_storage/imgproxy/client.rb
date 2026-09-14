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

      # "imgproxy was not reachable", and nothing was transferred: safe to ask
      # once more. Timeouts are deliberately absent.
      # EOFError is here as well as ECONNRESET: whether a peer that goes away
      # before answering surfaces as a reset or as an unexpected EOF depends on
      # the platform and on the timing, and both mean the same thing.
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

      # File signatures for the formats Active Storage can be asked for. A
      # format that is not in here is accepted on the status code alone.
      JPEG = ->(header) { header.start_with?("\xFF\xD8\xFF".b) }
      TIFF = ->(header) { header.start_with?("II*\x00".b) || header.start_with?("MM\x00*".b) }
      ISOBMFF = ->(brands) {
        ->(header) { header[4, 4] == "ftyp".b && brands.include?(header[8, 4]) }
      }

      MAGIC = {
        "png" => ->(header) { header.start_with?("\x89PNG\r\n\x1A\n".b) },
        "jpg" => JPEG,
        "jpeg" => JPEG,
        "gif" => ->(header) { header.start_with?("GIF8".b) },
        "webp" => ->(header) { header.start_with?("RIFF".b) && header[8, 4] == "WEBP".b },
        "avif" => ISOBMFF.call([ "avif".b, "avis".b ]),
        "heic" => ISOBMFF.call([ "heic".b, "heix".b, "heim".b, "heis".b, "mif1".b ]),
        "tif" => TIFF,
        "tiff" => TIFF,
        "bmp" => ->(header) { header.start_with?("BM".b) }
      }.freeze

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

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          # Net::HTTP's own retry would turn "one attempt" into two, doubling
          # both the work on imgproxy and the time this thread is held.
          http.max_retries = 0
          http.open_timeout = config.open_timeout
          http.read_timeout = config.timeout
          http.write_timeout = config.timeout

          http.start do |session|
            session.request(Net::HTTP::Get.new(uri)) do |response|
              check!(response)
              stream(response, into: into)
            end
          end
        end

        # Only the status code is ever reported. An imgproxy error body echoes
        # the source URL it was given, which is a presigned S3 URL or a signed
        # Disk URL -- credentials that have no business in a log line or in an
        # instrumentation payload.
        def check!(response)
          status = response.code.to_i

          raise RetriableResponse, "imgproxy responded #{status}" if RETRIABLE_STATUS.cover?(status)
          raise RequestFailed, "imgproxy responded #{status}" unless status == 200

          length = response["content-length"].to_i
          too_large!(length) if length > config.max_bytes
        end

        def stream(response, into:)
          written = 0

          response.read_body do |chunk|
            written += chunk.bytesize
            too_large!(written) if written > config.max_bytes

            into.write(chunk)
          end
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
          return if matches.nil? # a format this gem has no signature for

          header = tempfile.read(16).to_s.b
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
