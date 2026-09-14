# frozen_string_literal: true

module ActiveStorage
  module Imgproxy
    module Ext
      # ActiveStorage::Transformers::Transformer#process only receives an open
      # file and a format -- it never sees the blob. imgproxy, however, needs a
      # URL it can fetch the original from, which only the blob can produce.
      #
      # Both places that transform a blob into a variant open the blob and then
      # hand the file to the variation:
      #
      #   ActiveStorage::Variant#process           (activestorage/app/models/active_storage/variant.rb:111)
      #   ActiveStorage::VariantWithRecord#process (activestorage/app/models/active_storage/variant_with_record.rb:44)
      #
      # Both are private, take no arguments and expose a public #blob reader, so
      # a single prepended module covers the whole variant path (previews
      # included: ActiveStorage::Preview#process goes through Variant). The blob
      # is published for the duration of that call only and restored afterwards,
      # so nothing leaks between requests, jobs or threads.
      module BlobTracking
        private
          def process
            ActiveStorage::Imgproxy.with_blob(blob) { super }
          end
      end
    end
  end
end
