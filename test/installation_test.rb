# frozen_string_literal: true

require "test_helper"

# Documents *where* the gem hooks into Active Storage and why, and pins the
# behaviour of the Rails version this gem is built against, so that a future
# Rails upgrade that moves the ground fails here first.
class InstallationTest < Minitest::Test
  include ImgproxyTestHelper

  def test_active_storage_has_no_hook_that_can_see_the_blob
    # Rails 8.1 has ActiveStorage.variant_transformer, but a Transformer's only
    # entry point is #process(file, format:) -- an already-open file, never the
    # blob. imgproxy needs a URL, which only the blob can produce, so the gem
    # cannot be installed there no matter how the class is swapped in.
    assert_equal [ :file ], transformer_process_parameters.map(&:last).first(1)
    assert_equal %i[req keyreq], transformer_process_parameters.map(&:first)

    # And the accessor is not a configuration hook either: the engine overwrites
    # it unconditionally from :variant_processor in config.after_initialize,
    # which runs after config/initializers.
    assert_respond_to ActiveStorage, :variant_transformer
    assert_equal ActiveStorage::Transformers::Vips, ActiveStorage.variant_transformer
    refute_includes Rails.application.config.active_storage.keys, :variant_transformer
  end

  # The two places the gem prepends. Both are private, take no arguments and
  # expose a public #blob and #variation reader, which is what makes a single
  # small override possible.
  def test_the_hooked_methods_still_look_the_way_the_gem_expects
    [ ActiveStorage::Variant, ActiveStorage::VariantWithRecord ].each do |klass|
      assert_includes klass.private_instance_methods(false), :process, "#{klass} must define a private #process"
      assert_empty klass.instance_method(:process).parameters, "#{klass}#process must take no arguments"
      assert_includes klass.public_instance_methods, :blob
      assert_includes klass.public_instance_methods, :variation
    end
  end

  def test_the_gem_does_not_replace_the_stock_transformer
    variation = ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ], format: :png)

    assert_kind_of ActiveStorage.variant_transformer, variation.send(:transformer)
  end

  def test_the_format_is_not_passed_to_the_imgproxy_transformer_as_a_transformation
    stub_imgproxy
    events = captured_imgproxy_events do
      user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed
    end

    assert_equal({ resize_to_limit: [ 100, 100 ] }, events.first.payload[:transformations])
    assert_equal :png, events.first.payload[:format]
  end

  def test_when_disabled_nothing_is_attempted
    ActiveStorage::Imgproxy.config.enabled = false

    assert_nil ActiveStorage::Imgproxy.transform(
      user_with_avatar.avatar.blob, ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ])
    )
  end

  def test_the_tracked_variant_path_also_runs_on_imgproxy
    seen = nil
    stub_request(:get, %r{\A#{Regexp.escape(ImgproxyTestHelper::IMGPROXY_URL)}/}).to_return do
      seen = ActiveStorage::Imgproxy.current_blob
      { status: 200, body: ImgproxyTestHelper::TRANSFORMED_PNG }
    end

    with_tracked_variants do
      blob = user_with_avatar.avatar.blob
      variant = blob.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

      assert_kind_of ActiveStorage::VariantWithRecord, variant
      assert_equal blob, seen
      assert_equal ImgproxyTestHelper::TRANSFORMED_PNG, variant.download
      assert_equal "image/png", variant.image.blob.content_type
      assert_equal "sample.png", variant.image.blob.filename.to_s
    end
  end

  def test_the_tracked_variant_path_falls_back_intact
    stub_imgproxy(status: 500)

    with_tracked_variants do
      blob = user_with_avatar.avatar.blob
      variant = blob.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

      assert_kind_of ActiveStorage::VariantWithRecord, variant
      assert_equal "image/png", variant.image.blob.content_type
      assert_equal "sample.png", variant.image.blob.filename.to_s
      assert_operator variant.download.bytesize, :>, 0
    end
  end

  private
    def transformer_process_parameters
      ActiveStorage::Transformers::Transformer.instance_method(:process).parameters
    end

    def with_tracked_variants
      previous = ActiveStorage.track_variants
      ActiveStorage.track_variants = true
      yield
    ensure
      ActiveStorage.track_variants = previous
      ActiveStorage::VariantRecord.delete_all
    end
end
