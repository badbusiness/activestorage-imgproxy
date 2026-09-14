# frozen_string_literal: true

require "active_storage"

module ActiveStorage
  module Transformers
    # Performs the variant transformation on a shared imgproxy container.
    #
    # The original never leaves the app's own storage: imgproxy is handed a
    # short-lived, signed URL that the app generates itself (a presigned S3 URL
    # for the S3 services, the signed /rails/active_storage/disk/... URL for the
    # Disk service), so imgproxy needs neither credentials nor volume mounts.
    #
    # Any problem at all -- an untranslatable transformation, missing
    # configuration, a blob that cannot produce a URL, a timeout, a 4xx or a
    # 5xx -- logs one warning and falls back to the transformer Active Storage
    # would otherwise have used. imgproxy being down must never produce a 500.
    class ImgproxyTransformer < Transformer
      NOTIFICATION = "transform.imgproxy"

      attr_reader :fallback

      def initialize(transformations, fallback:)
        super(transformations)
        @fallback = fallback
      end

      private
        def process(file, format:)
          started = monotonic_now
          payload = { transformations: transformations, format: format, fallback: false }

          ActiveSupport::Notifications.instrument(NOTIFICATION, payload) do
            begin
              imgproxy_process(format: format).tap do
                payload[:duration] = monotonic_now - started
              end
            rescue ActiveStorage::Imgproxy::Error => error
              payload[:fallback] = true
              payload[:error] = "#{error.class}: #{error.message}"
              payload[:duration] = monotonic_now - started

              warn_about(error)
              fallback_process(file, format: format)
            end
          end
        end

        def imgproxy_process(format:)
          config = ActiveStorage::Imgproxy.config.validate!
          blob = ActiveStorage::Imgproxy.current_blob

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
        rescue ArgumentError, URI::InvalidURIError => error
          raise ActiveStorage::Imgproxy::UnavailableSource, error.message
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

        def fallback_process(file, format:)
          file.rewind if file.respond_to?(:rewind)
          fallback.send(:process, file, format: format)
        end

        def warn_about(error)
          ActiveStorage::Imgproxy.logger&.warn(
            "[activestorage-imgproxy] falling back to #{fallback.class.name}: #{error.class}: #{error.message}"
          )
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
    end
  end
end
