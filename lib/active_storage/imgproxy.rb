# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/hash/except"
require "active_support/core_ext/string/filters"
require "active_support/notifications"
require "active_storage"

require "active_storage/imgproxy/version"
require "active_storage/imgproxy/configuration"
require "active_storage/imgproxy/translator"
require "active_storage/imgproxy/url_builder"
require "active_storage/imgproxy/client"
require "active_storage/imgproxy/ext/variant"
require "active_storage/imgproxy/ext/variant_with_record"
require "active_storage/transformers/imgproxy_transformer"

module ActiveStorage
  # Runs Active Storage variant transformations on a shared imgproxy container
  # instead of in the Ruby process, and falls back to the stock transformer
  # whenever imgproxy cannot do the job.
  module Imgproxy
    class Error < StandardError; end

    # The transformations cannot be expressed in imgproxy processing options.
    class UnsupportedTransformation < Error; end

    # imgproxy is not (fully) configured.
    class MissingConfiguration < Error; end

    # imgproxy could not be reached or refused the request.
    class RequestFailed < Error; end

    # The blob could not be turned into a URL imgproxy can fetch.
    class UnavailableSource < Error; end

    BLOB_KEY = :active_storage_imgproxy_blob
    private_constant :BLOB_KEY

    class << self
      def config
        @config ||= Configuration.new
      end

      def configure
        yield config
        config
      end

      # Resets the configuration to the environment defaults. Mainly useful in
      # tests.
      def reset_config!
        @config = Configuration.new
      end

      # Runs the variation on imgproxy. Returns an open, rewound Tempfile with
      # the transformed image, or nil when the caller should run the stock
      # Active Storage path instead. Never raises on the imgproxy path.
      def transform(blob, variation)
        return nil unless config.enabled?

        transformer = ActiveStorage::Transformers::ImgproxyTransformer.new(
          variation.transformations.except(:format)
        )

        with_blob(blob) { transformer.attempt(blob, format: variation.format) }
      rescue => error
        # ImgproxyTransformer#attempt guards everything it does, but the few
        # lines above it are on the imgproxy path too: config.enabled? reads
        # configuration that is built lazily from the environment, and
        # variation.format validates the requested format. Neither may turn a
        # variant into a 500 -- the stock path runs next and will raise the same
        # thing itself if it really is the app's problem.
        logger&.warn("[activestorage-imgproxy] falling back to the stock transformer: #{error.class}: #{error.message}")
        nil
      end

      # Prepends the hooks the gem needs. Idempotent, and safe to call again
      # after a code reload, because it checks the ancestors of the (possibly
      # new) class objects rather than a global flag.
      def install!
        install_module(ActiveStorage::Variant, Ext::Variant)
        install_module(ActiveStorage::VariantWithRecord, Ext::VariantWithRecord)
        true
      end

      def installed?
        ActiveStorage::Variant.ancestors.include?(Ext::Variant) &&
          ActiveStorage::VariantWithRecord.ancestors.include?(Ext::VariantWithRecord)
      end

      # Publishes the blob being transformed for the duration of the block, so
      # that ImgproxyTransformer can also be used through the plain Transformer
      # interface.
      def with_blob(blob)
        previous = Thread.current[BLOB_KEY]
        Thread.current[BLOB_KEY] = blob
        yield
      ensure
        Thread.current[BLOB_KEY] = previous
      end

      def current_blob
        Thread.current[BLOB_KEY]
      end

      def logger
        ActiveStorage.logger || (defined?(Rails) && Rails.logger)
      end

      private
        def install_module(klass, mod)
          klass.prepend(mod) unless klass.ancestors.include?(mod)
        end
    end
  end
end

require "active_storage/imgproxy/railtie" if defined?(Rails::Railtie)
