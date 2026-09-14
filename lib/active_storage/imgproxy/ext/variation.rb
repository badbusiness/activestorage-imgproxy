# frozen_string_literal: true

module ActiveStorage
  module Imgproxy
    module Ext
      # Injects the imgproxy transformer.
      #
      # ActiveStorage::Variation#transformer (activestorage/app/models/active_storage/variation.rb:84)
      # is the single place where Active Storage decides which transformer runs.
      # Rails 8.1 added the ActiveStorage.variant_transformer accessor
      # (activestorage/lib/active_storage.rb:53), but it is not a configuration
      # hook: the engine overwrites it unconditionally from :variant_processor
      # in a config.after_initialize block (activestorage/lib/active_storage/engine.rb:96),
      # which runs *after* config/initializers. Rails 7.1, 7.2 and 8.0 do not
      # have the accessor at all and hardcode ImageProcessingTransformer.
      #
      # Prepending is therefore the only hook that works on every supported
      # version. super is kept reachable so that :enabled = false is completely
      # transparent and the transformer can fall back to the stock one.
      module Variation
        private
          def transformer
            default = super
            return default unless ActiveStorage::Imgproxy.config.enabled?

            ActiveStorage::Transformers::ImgproxyTransformer.new(
              transformations.except(:format), fallback: default
            )
          end
      end
    end
  end
end
