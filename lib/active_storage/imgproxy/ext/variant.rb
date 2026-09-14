# frozen_string_literal: true

module ActiveStorage
  module Imgproxy
    module Ext
      # The hook sits on ActiveStorage::Variant#process, one level *above* the
      # transformer:
      #
      #   ActiveStorage::Variant#process (activestorage/app/models/active_storage/variant.rb:111)
      #
      #     def process
      #       blob.open do |input|
      #         variation.transform(input) do |output|
      #           service.upload(key, output, content_type: content_type)
      #         end
      #       end
      #     end
      #
      # Hooking the transformer instead would be neater, but a Transformer only
      # ever receives an already-open file -- which means the stock code has
      # *already* streamed the whole original out of storage and checksummed it
      # (ActiveStorage::Blob#open downloads to a tempfile and verifies its MD5)
      # before imgproxy is even asked. On the imgproxy path that download is
      # pure waste: imgproxy fetches the original itself, from a signed URL.
      # On a Disk-service app it is worse than waste, because the app then
      # serves that same original back to imgproxy over a second connection.
      #
      # So: try imgproxy with nothing but the blob, and only open the blob when
      # imgproxy could not do the job -- at which point `super` runs the
      # completely untouched stock implementation.
      module Variant
        private
          def process
            output = ActiveStorage::Imgproxy.transform(blob, variation)
            return super if output.nil?

            begin
              service.upload(key, output, content_type: content_type)
            ensure
              output.close!
            end
          end
      end
    end
  end
end
