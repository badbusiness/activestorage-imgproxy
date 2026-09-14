# frozen_string_literal: true

require "base64"
require "openssl"

module ActiveStorage
  module Imgproxy
    # Builds a signed imgproxy v3 URL:
    #
    #   {base}/{signature}/{processing options}/{base64url source}.{extension}
    #
    # The base64 source form is used rather than /plain/, because the source is
    # a presigned S3 URL or a signed Disk URL: both are long and full of
    # characters that would otherwise have to be percent-encoded twice.
    #
    # The signature is HMAC-SHA256 over the hex-decoded salt followed by the
    # path that starts at the processing options, base64url encoded without
    # padding. Verified against the test vector in the imgproxy documentation
    # (see test/url_builder_test.rb).
    class UrlBuilder
      def initialize(config)
        @config = config
      end

      def build(source_url:, options:, extension:)
        path = +"/"
        path << options.join("/") << "/" unless options.empty?
        path << Base64.urlsafe_encode64(source_url, padding: false)
        path << "." << extension.to_s.downcase

        "#{config.url.to_s.chomp('/')}/#{sign(path)}#{path}"
      end

      private
        attr_reader :config

        def sign(path)
          digest = OpenSSL::HMAC.digest("sha256", hex(config.key), hex(config.salt) + path)
          Base64.urlsafe_encode64(digest, padding: false)
        end

        # pack("H*") happily turns "not hex at all" into bytes by looking at the
        # low nibble of every character, so the string has to be checked before
        # it is decoded -- otherwise a typo in IMGPROXY_KEY produces a perfectly
        # well-formed signature that imgproxy rejects with a 403 on every single
        # variant.
        def hex(value)
          unless Configuration::HEX.match?(value.to_s)
            raise MissingConfiguration, "imgproxy key and salt must be hex encoded"
          end

          [ value.to_s ].pack("H*")
        end
    end
  end
end
