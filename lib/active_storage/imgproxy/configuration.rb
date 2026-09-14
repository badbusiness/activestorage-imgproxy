# frozen_string_literal: true

module ActiveStorage
  module Imgproxy
    # Runtime configuration for the imgproxy transformer.
    #
    # Every value defaults to an environment variable so that an app only needs
    # to set env in its deploy config. Values can be overridden in an
    # initializer through ActiveStorage::Imgproxy.configure.
    class Configuration
      DEFAULT_URL_EXPIRES_IN = 300
      DEFAULT_TIMEOUT = 30

      attr_accessor :url, :key, :salt, :source_host, :url_expires_in, :timeout
      attr_writer :enabled

      def initialize
        @url = presence(ENV["IMGPROXY_URL"])
        @key = presence(ENV["IMGPROXY_KEY"])
        @salt = presence(ENV["IMGPROXY_SALT"])
        @source_host = presence(ENV["IMGPROXY_SOURCE_HOST"])
        @url_expires_in = integer(ENV["IMGPROXY_URL_EXPIRES_IN"], DEFAULT_URL_EXPIRES_IN)
        @timeout = integer(ENV["IMGPROXY_TIMEOUT"], DEFAULT_TIMEOUT)
        @enabled = boolean(ENV["IMGPROXY_ENABLED"], true)
      end

      # The transformer only runs when it is switched on *and* fully
      # configured. Anything missing means every transformation transparently
      # falls back to the stock Active Storage transformer.
      def enabled?
        @enabled && url.present? && key.present? && salt.present?
      end

      # Raises when something required is missing, so the transformer can log a
      # single actionable warning and fall back.
      def validate!
        missing = []
        missing << "IMGPROXY_URL" if url.blank?
        missing << "IMGPROXY_KEY" if key.blank?
        missing << "IMGPROXY_SALT" if salt.blank?

        raise MissingConfiguration, "missing imgproxy configuration: #{missing.join(', ')}" if missing.any?

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
