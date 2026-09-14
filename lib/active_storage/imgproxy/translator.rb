# frozen_string_literal: true

module ActiveStorage
  module Imgproxy
    # Translates an Active Storage transformations hash (the ImageProcessing
    # vocabulary) into imgproxy v3 processing options.
    #
    # Anything this class does not understand raises UnsupportedTransformation,
    # which makes the transformer fall back to the stock vips transformer. That
    # is deliberate: it is always better to be slow than to be wrong.
    class Translator
      # image_processing / vips gravity names mapped onto imgproxy gravity types.
      GRAVITY = {
        "centre" => "ce", "center" => "ce",
        "north" => "no", "top" => "no",
        "south" => "so", "bottom" => "so",
        "east" => "ea", "right" => "ea",
        "west" => "we", "left" => "we",
        "north-east" => "noea", "north-west" => "nowe",
        "south-east" => "soea", "south-west" => "sowe",
        "attention" => "sm", "entropy" => "sm", "smart" => "sm"
      }.freeze

      # resize_* transformations and the imgproxy resizing type + enlarge flag
      # they correspond to. resize_to_limit only ever downsizes; resize_to_fit
      # and resize_to_fill also upsize.
      RESIZE = {
        resize_to_limit: [ "fit", 0 ],
        resize_to_fit: [ "fit", 1 ],
        resize_to_fill: [ "fill", 1 ]
      }.freeze

      def initialize(transformations)
        @transformations = (transformations || {}).symbolize_keys
      end

      # Returns the processing options as an array of "option:args" segments.
      def call
        options = []

        transformations.each do |name, argument|
          next if argument.nil?

          options.concat(translate(name, argument))
        end

        options << "q:#{quality}" if quality
        options
      end

      private
        attr_reader :transformations

        def translate(name, argument)
          case name
          when *RESIZE.keys then resize(name, argument)
          when :resize_and_pad then resize_and_pad(argument)
          when :quality then [] # handled by #quality
          when :saver then saver_options(argument)
          when :strip then argument ? [ "sm:1" ] : []
          when :auto_orient then argument ? [] : [ "ar:0" ] # imgproxy auto-rotates by default
          when :format then [] # carried by the URL extension
          else
            raise UnsupportedTransformation, "unsupported transformation #{name.inspect}"
          end
        end

        # :saver carries format-specific writer options. Only :quality (read by
        # #quality) and :strip translate to imgproxy; anything else falls back.
        def saver_options(argument)
          raise UnsupportedTransformation, "unsupported saver #{argument.inspect}" unless argument.is_a?(Hash)

          saver = argument.symbolize_keys
          reject_unknown_options(:saver, saver, %i[quality strip])
          saver[:strip] ? [ "sm:1" ] : []
        end

        def resize(name, argument)
          type, enlarge = RESIZE.fetch(name)
          width, height, options = split(argument)

          segments = [ "rs:#{type}:#{width}:#{height}:#{enlarge}" ]
          segments << gravity(options[:crop] || options[:gravity]) if options.key?(:crop) || options.key?(:gravity)
          reject_unknown_options(name, options, %i[crop gravity])
          segments
        end

        def resize_and_pad(argument)
          width, height, options = split(argument)

          segments = [ "rs:fit:#{width}:#{height}:1", "ex:1:#{padding_gravity(options[:gravity])}" ]
          segments << background(options[:background]) if options.key?(:background)
          reject_unknown_options(:resize_and_pad, options, %i[gravity background alpha])
          segments
        end

        # resize_* arguments come in as [width, height] or [width, height, options].
        def split(argument)
          raise UnsupportedTransformation, "expected an array of dimensions, got #{argument.inspect}" unless argument.is_a?(Array)

          width, height, *rest = argument
          options = rest.last.is_a?(Hash) ? rest.last.symbolize_keys : {}

          [ dimension(width), dimension(height), options ]
        end

        # imgproxy reads 0 as "derive from the other dimension", which is what
        # a nil dimension means in ImageProcessing.
        def dimension(value)
          return 0 if value.nil?

          integer = Integer(value)
          raise UnsupportedTransformation, "negative dimension #{value.inspect}" if integer.negative?

          integer
        rescue ArgumentError, TypeError
          raise UnsupportedTransformation, "non-numeric dimension #{value.inspect}"
        end

        def gravity(value)
          type = GRAVITY[value.to_s.downcase]
          raise UnsupportedTransformation, "unsupported gravity #{value.inspect}" if type.nil?

          "g:#{type}"
        end

        def padding_gravity(value)
          return "ce" if value.nil?

          gravity(value).delete_prefix("g:")
        end

        def background(value)
          case value
          when Array
            raise UnsupportedTransformation, "background must be three channels" unless value.size == 3

            "bg:#{value.map { |channel| Integer(channel) }.join(':')}"
          when String
            hex = value.delete_prefix("#")
            raise UnsupportedTransformation, "background must be a hex colour" unless hex.match?(/\A[0-9a-fA-F]{6}\z/)

            "bg:#{hex}"
          else
            raise UnsupportedTransformation, "unsupported background #{value.inspect}"
          end
        end

        def reject_unknown_options(name, options, allowed)
          unknown = options.keys - allowed
          raise UnsupportedTransformation, "unsupported #{name} options #{unknown.inspect}" if unknown.any?
        end

        # quality can arrive either top level or nested under :saver.
        def quality
          saver = transformations[:saver]
          saver = saver.symbolize_keys if saver.is_a?(Hash)

          value = transformations[:quality] || (saver.is_a?(Hash) ? saver[:quality] : nil)
          return nil if value.nil?

          integer = Integer(value)
          raise UnsupportedTransformation, "quality out of range #{value.inspect}" unless integer.between?(1, 100)

          integer
        rescue ArgumentError, TypeError
          raise UnsupportedTransformation, "non-numeric quality"
        end
    end
  end
end
