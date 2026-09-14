# frozen_string_literal: true

module ActiveStorage
  module Imgproxy
    module Ext
      # The same hook as Ext::Variant, for the tracked-variant path:
      #
      #   ActiveStorage::VariantWithRecord#process (activestorage/app/models/active_storage/variant_with_record.rb:43)
      #
      #     def process
      #       transform_blob { |image| create_or_find_record(image: image) }
      #     end
      #
      # #transform_blob is the part that opens the blob, so it is bypassed
      # rather than called; the attachment hash handed to #create_or_find_record
      # is built exactly as the stock implementation builds it.
      module VariantWithRecord
        private
          def process
            output = ActiveStorage::Imgproxy.transform(blob, variation)
            return super if output.nil?

            begin
              create_or_find_record(image: {
                io: output,
                filename: "#{blob.filename.base}.#{variation.format.downcase}",
                content_type: variation.content_type,
                service_name: blob.service.name
              })
            ensure
              output.close!
            end
          end
      end
    end
  end
end
