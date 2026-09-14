# frozen_string_literal: true

require "net/http"
require "openssl"
require "tempfile"
require "uri"

module ActiveStorage
  module Imgproxy
    # Fetches a transformed image from imgproxy over plain HTTP.
    #
    # One retry on a timeout or a 5xx; a 4xx is not retried because imgproxy
    # will not change its mind about a malformed or forbidden request. Every
    # failure raises RequestFailed, which the transformer turns into a fallback.
    class Client
      RETRIABLE_STATUS = (500..599).freeze
      MAX_ATTEMPTS = 2

      # Everything that means "imgproxy did not answer properly": timeouts
      # (Net::OpenTimeout/ReadTimeout/WriteTimeout all descend from
      # Timeout::Error), a dropped connection, a refused connection, an
      # unresolvable host, and TLS trouble.
      RETRIABLE_ERRORS = [
        Timeout::Error, IOError, SystemCallError, SocketError, Net::ProtocolError, OpenSSL::SSL::SSLError
      ].freeze

      def initialize(config)
        @config = config
      end

      # Returns an open, rewound, binary Tempfile with the transformed image.
      def download(url, extension:)
        body = get(URI.parse(url))

        tempfile = Tempfile.new([ "ActiveStorage-imgproxy-", ".#{extension}" ], binmode: true)
        tempfile.write(body)
        tempfile.flush
        tempfile.rewind
        tempfile
      end

      private
        attr_reader :config

        def get(uri)
          attempt = 0

          begin
            attempt += 1
            perform(uri)
          rescue *RETRIABLE_ERRORS, RetriableResponse => error
            retry if attempt < MAX_ATTEMPTS

            raise RequestFailed, "imgproxy request failed after #{attempt} attempts: #{error.message}"
          end
        end

        def perform(uri)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = config.timeout
          http.read_timeout = config.timeout
          http.write_timeout = config.timeout

          response = http.start { |session| session.request(Net::HTTP::Get.new(uri)) }
          status = response.code.to_i

          raise RetriableResponse, "imgproxy responded #{status}" if RETRIABLE_STATUS.cover?(status)
          raise RequestFailed, "imgproxy responded #{status}: #{response.body.to_s.truncate(200)}" unless status == 200

          response.body
        end

        class RetriableResponse < StandardError; end
        private_constant :RetriableResponse
    end
  end
end
