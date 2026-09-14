# frozen_string_literal: true

require "test_helper"

# Documents *why* the gem prepends instead of using a configuration hook, and
# pins the behaviour of the Rails version this gem is built against, so that a
# future Rails upgrade that does add a real hook fails here first.
class InstallationTest < Minitest::Test
  include ImgproxyTestHelper

  def test_active_storage_has_no_configuration_hook_for_a_custom_transformer
    # Rails 8.1 added ActiveStorage.variant_transformer, but the engine
    # overwrites it from :variant_processor in config.after_initialize, which
    # runs after config/initializers. Assigning it is therefore not a hook.
    assert_respond_to ActiveStorage, :variant_transformer
    assert_equal ActiveStorage::Transformers::Vips, ActiveStorage.variant_transformer

    # config.active_storage.variant_transformer is never read by the engine:
    # it is not part of the Active Storage configuration at all.
    refute_includes Rails.application.config.active_storage.keys, :variant_transformer

    # The engine's own assignment happens in config.after_initialize, i.e.
    # after config/initializers have run, so an initializer cannot win either.
  end

  def test_the_transformer_is_injected_through_variation
    variation = ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ], format: :png)

    assert_kind_of ActiveStorage::Transformers::ImgproxyTransformer, variation.send(:transformer)
  end

  def test_the_format_is_not_passed_to_the_transformer_as_a_transformation
    variation = ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ], format: :png)

    assert_equal({ resize_to_limit: [ 100, 100 ] }, variation.send(:transformer).transformations)
  end

  def test_the_fallback_is_the_transformer_active_storage_would_have_used
    variation = ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ], format: :png)

    assert_kind_of ActiveStorage.variant_transformer, variation.send(:transformer).fallback
  end

  def test_when_disabled_variation_returns_the_stock_transformer
    ActiveStorage::Imgproxy.config.enabled = false
    variation = ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ], format: :png)

    assert_kind_of ActiveStorage.variant_transformer, variation.send(:transformer)
    refute_kind_of ActiveStorage::Transformers::ImgproxyTransformer, variation.send(:transformer)
  end

  def test_the_tracked_variant_path_also_publishes_the_blob
    stub_imgproxy
    seen = nil
    stub_request(:get, %r{\Ahttp://imgproxy:8080/}).to_return do
      seen = ActiveStorage::Imgproxy.current_blob
      { status: 200, body: ImgproxyTestHelper::TRANSFORMED_PNG }
    end

    with_tracked_variants do
      blob = user_with_avatar.avatar.blob
      variant = blob.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

      assert_kind_of ActiveStorage::VariantWithRecord, variant
      assert_equal blob, seen
      assert_equal ImgproxyTestHelper::TRANSFORMED_PNG, variant.download
    end
  end

  private
    def with_tracked_variants
      previous = ActiveStorage.track_variants
      ActiveStorage.track_variants = true
      yield
    ensure
      ActiveStorage.track_variants = previous
      ActiveStorage::VariantRecord.delete_all
    end
end
