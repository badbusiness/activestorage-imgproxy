# frozen_string_literal: true

require "active_storage"

module ActiveStorage
  module Transformers
    # Performs the variant transformation on a shared imgproxy container.
    #
    # This class is the gem's internal implementation, driven from
    # ActiveStorage::Imgproxy::Ext::Variant. It is not installed as Active
    # Storage's variant_transformer, because a Transformer only ever receives an
    # open file and never the blob -- and the blob is the only thing that can
    # produce a URL imgproxy can fetch the original from.
    #
    # The original never leaves the app's own storage: imgproxy is handed a
    # short-lived, signed URL that the app generates itself (a presigned S3 URL
    # for the S3 services, the signed /rails/active_storage/disk/... URL for the
    # Disk service), so imgproxy needs neither credentials nor volume mounts.
    #
    # Any problem at all -- an untranslatable transformation, missing
    # configuration, a blob that cannot produce a URL, a timeout, a 4xx, a 5xx,
    # a full disk, a typo in IMGPROXY_URL -- logs one warning and returns nil,
    # so that the caller runs the stock Active Storage path instead. imgproxy
    # being down must never produce a 500, which is why the rescue below is
    # deliberately as wide as StandardError: the fallback is always correct,
    # only slower.
    class ImgproxyTransformer < Transformer
      NOTIFICATION = "transform.imgproxy"

      # Returns an open, rewound Tempfile with the transformed image, or nil
      # when imgproxy could not deliver one. Never raises.
      def attempt(blob, format:)
        started = monotonic_now
        payload = { transformations: transformations, format: format, fallback: false }

        ActiveSupport::Notifications.instrument(NOTIFICATION, payload) do
          begin
            imgproxy_process(blob, format: format)
          rescue => error
            payload[:fallback] = true
            payload[:error] = "#{error.class}: #{error.message}"
            warn_about(error)
            nil
          ensure
            payload[:duration] = monotonic_now - started
          end
        end
      end

      private
        # Transformer#transform contract, kept working so the class stays a
        # legitimate Transformer. The file argument is ignored -- imgproxy reads
        # the original from storage itself -- and the blob comes from the scope
        # Ext::Variant publishes.
        def process(file, format:)
          imgproxy_process(ActiveStorage::Imgproxy.current_blob, format: format)
        end

        def imgproxy_process(blob, format:)
          config = ActiveStorage::Imgproxy.config.validate!

          raise ActiveStorage::Imgproxy::UnavailableSource, "no blob in scope" if blob.nil?

          options = ActiveStorage::Imgproxy::Translator.new(transformations).call
          url = ActiveStorage::Imgproxy::UrlBuilder.new(config).build(
            source_url: source_url_for(blob, config), options: options, extension: format
          )

          ActiveStorage::Imgproxy::Client.new(config).download(url, extension: format)
        end

        # blob.url is a presigned URL on S3-like services; on the Disk service it
        # is the app's own signed /rails/active_storage/disk/... URL, which needs
        # a host. There is no request in a background job, so the host comes from
        # the configured source_host.
        def source_url_for(blob, config)
          with_url_options(config) { blob.url(expires_in: config.url_expires_in) }
        end

        def with_url_options(config)
          options = config.source_url_options

          return yield if options.nil?

          previous = ActiveStorage::Current.url_options
          ActiveStorage::Current.url_options = options
          begin
            yield
          ensure
            ActiveStorage::Current.url_options = previous
          end
        end

        # Only the class and message, never a response body: imgproxy echoes the
        # signed source URL in its error bodies.
        def warn_about(error)
          ActiveStorage::Imgproxy.logger&.warn(
            "[activestorage-imgproxy] falling back to the stock transformer: #{error.class}: #{error.message}"
          )
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
    end
  end
end
