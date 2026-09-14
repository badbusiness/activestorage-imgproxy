# frozen_string_literal: true

require "uri"

module ActiveStorage
  module Imgproxy
    # Runtime configuration for the imgproxy transformer.
    #
    # Every value defaults to an environment variable so that an app only needs
    # to set env in its deploy config. Values can be overridden in an
    # initializer through ActiveStorage::Imgproxy.configure.
    class Configuration
      DEFAULT_URL_EXPIRES_IN = 300

      # Deliberately short. A slow imgproxy must never hold a web thread: the
      # stock vips path is the correct answer, just a slower one. These must
      # stay *below* the container's own IMGPROXY_TIMEOUT, so that the gem gives
      # up before imgproxy does and no work is left running on the other side.
      DEFAULT_OPEN_TIMEOUT = 2
      DEFAULT_TIMEOUT = 10

      # Hard ceiling on the response imgproxy is allowed to stream back. A
      # variant that does not fit is a misconfiguration, not something to buffer.
      DEFAULT_MAX_BYTES = 64 * 1024 * 1024

      # imgproxy keys and salts are hex encoded, always an even number of digits.
      HEX = /\A(?:\h\h)+\z/

      attr_accessor :url, :key, :salt, :source_host, :url_expires_in,
                    :timeout, :open_timeout, :max_bytes
      attr_writer :enabled

      def initialize
        @url = presence(ENV["IMGPROXY_URL"])
        @key = presence(ENV["IMGPROXY_KEY"])
        @salt = presence(ENV["IMGPROXY_SALT"])
        @source_host = presence(ENV["IMGPROXY_SOURCE_HOST"])
        @url_expires_in = integer(ENV["IMGPROXY_URL_EXPIRES_IN"], DEFAULT_URL_EXPIRES_IN)
        @open_timeout = integer(ENV["IMGPROXY_OPEN_TIMEOUT"], DEFAULT_OPEN_TIMEOUT)
        @timeout = integer(ENV["IMGPROXY_TIMEOUT"], DEFAULT_TIMEOUT)
        @max_bytes = integer(ENV["IMGPROXY_MAX_BYTES"], DEFAULT_MAX_BYTES)
        @enabled = boolean(ENV["IMGPROXY_ENABLED"], true)
      end

      # The transformer only runs when it is switched on *and* fully
      # configured. Anything missing means every transformation transparently
      # falls back to the stock Active Storage transformer.
      #
      # It also stays out of the way when Active Storage itself has variant
      # processing disabled (variant_processor: :disabled, which installs the
      # NullTransformer): an app that asked for no image processing at all must
      # not suddenly get it from this gem.
      def enabled?
        @enabled && url.present? && key.present? && salt.present? && !variants_disabled?
      end

      # Raises when something required is missing or malformed, so the
      # transformer can log a single actionable warning and fall back.
      def validate!
        missing = []
        missing << "IMGPROXY_URL" if url.blank?
        missing << "IMGPROXY_KEY" if key.blank?
        missing << "IMGPROXY_SALT" if salt.blank?

        raise MissingConfiguration, "missing imgproxy configuration: #{missing.join(', ')}" if missing.any?

        malformed = []
        malformed << "IMGPROXY_KEY" unless HEX.match?(key)
        malformed << "IMGPROXY_SALT" unless HEX.match?(salt)

        if malformed.any?
          raise MissingConfiguration,
            "imgproxy configuration must be hex encoded: #{malformed.join(', ')}"
        end

        self
      end

      # Parsed URL options for ActiveStorage::Current.url_options, derived from
      # source_host. Needed by the Disk service, which cannot build a URL
      # without a host (there is no request in a background job).
      def source_url_options
        return nil if source_host.blank?

        uri = URI.parse(source_host)
        raise MissingConfiguration, "IMGPROXY_SOURCE_HOST must be an absolute URL" if uri.host.blank?

        options = { protocol: uri.scheme || "http", host: uri.host }
        options[:port] = uri.port unless uri.port == uri.default_port
        options
      end

      private
        def variants_disabled?
          defined?(ActiveStorage::Transformers::NullTransformer) &&
            ActiveStorage.respond_to?(:variant_transformer) &&
            ActiveStorage.variant_transformer == ActiveStorage::Transformers::NullTransformer
        end

        def presence(value)
          value if value && !value.strip.empty?
        end

        def integer(value, default)
          value.present? ? Integer(value) : default
        end

        def boolean(value, default)
          return default if value.nil? || value.strip.empty?

          !%w[0 false no off].include?(value.strip.downcase)
        end
    end
  end
end
