# frozen_string_literal: true

require "test_helper"

class TransformerTest < Minitest::Test
  include ImgproxyTestHelper
  include ActiveSupport::Testing::TimeHelpers

  def test_the_variant_is_fetched_from_imgproxy
    stub = stub_imgproxy
    variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_requested stub, times: 1
    assert_equal ImgproxyTestHelper::TRANSFORMED_PNG, variant.download
  end

  def test_the_request_carries_the_signed_processing_options_and_the_blob_url
    stub_imgproxy
    blob = user_with_avatar.avatar.blob
    blob.attachments.first.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    path = URI.parse(requested_url).path
    _, signature, options, source = path.split("/")

    assert_equal "rs:fit:100:100:0", options
    assert_equal signature, expected_signature("/#{options}/#{source}")

    source_url = Base64.urlsafe_decode64(source.delete_suffix(".png"))
    assert_includes source_url, "http://dashboard.test/rails/active_storage/disk/"
  end

  def test_the_source_url_is_signed_and_expires
    stub_imgproxy
    ActiveStorage::Imgproxy.config.url_expires_in = 60
    user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    source_url = Base64.urlsafe_decode64(URI.parse(requested_url).path.split("/").last.delete_suffix(".png"))
    token = source_url[%r{/disk/([^/]+)/}, 1]

    refute_nil ActiveStorage.verifier.verified(token, purpose: :blob_key), "token must verify right now"

    travel 61.seconds do
      assert_nil ActiveStorage.verifier.verified(token, purpose: :blob_key), "token must have expired"
    end
  end

  def test_a_500_is_retried_once_and_then_falls_back
    stub = stub_imgproxy(status: 500, body: "boom")
    variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_requested stub, times: 2
    assert_equal vanilla_variant_bytes(resize_to_limit: [ 100, 100 ], format: :png), variant.download
  end

  def test_a_timeout_is_retried_once_and_then_falls_back
    stub = stub_request(:get, %r{\Ahttp://imgproxy:8080/}).to_timeout
    variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_requested stub, times: 2
    assert_equal vanilla_variant_bytes(resize_to_limit: [ 100, 100 ], format: :png), variant.download
  end

  def test_a_4xx_is_not_retried_and_falls_back
    stub = stub_imgproxy(status: 422, body: "invalid processing options")
    variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_requested stub, times: 1
    assert_equal vanilla_variant_bytes(resize_to_limit: [ 100, 100 ], format: :png), variant.download
  end

  def test_an_untranslatable_transformation_falls_back_without_calling_imgproxy
    stub = stub_imgproxy
    variant = user_with_avatar.avatar.variant(rotate: 90, format: :png).processed

    assert_not_requested stub
    assert_equal vanilla_variant_bytes(rotate: 90, format: :png), variant.download
  end

  def test_missing_configuration_falls_back_without_calling_imgproxy
    stub = stub_imgproxy
    ActiveStorage::Imgproxy.config.key = nil
    variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_not_requested stub
    assert_equal vanilla_variant_bytes(resize_to_limit: [ 100, 100 ], format: :png), variant.download
  end

  def test_a_disk_blob_without_a_source_host_falls_back
    stub = stub_imgproxy
    ActiveStorage::Imgproxy.config.source_host = nil
    variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_not_requested stub
    assert_equal vanilla_variant_bytes(resize_to_limit: [ 100, 100 ], format: :png), variant.download
  end

  def test_disabled_is_completely_transparent
    stub = stub_imgproxy
    ActiveStorage::Imgproxy.config.enabled = false

    events = captured_imgproxy_events do
      variant = user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed
      assert_equal vanilla_variant_bytes(resize_to_limit: [ 100, 100 ], format: :png), variant.download
    end

    assert_not_requested stub
    assert_empty events
    assert_kind_of ActiveStorage::Transformers::ImageProcessingTransformer, stock_transformer
  end

  def test_instrumentation_on_the_happy_path
    stub_imgproxy

    events = captured_imgproxy_events do
      user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed
    end

    assert_equal 1, events.size
    assert_equal false, events.first.payload[:fallback]
    assert_equal :png, events.first.payload[:format]
    assert_equal({ resize_to_limit: [ 100, 100 ] }, events.first.payload[:transformations])
    assert_operator events.first.payload[:duration], :>=, 0
    refute events.first.payload.key?(:error)
  end

  def test_instrumentation_and_a_single_warning_on_the_fallback_path
    stub_imgproxy(status: 500)
    log = StringIO.new
    ActiveStorage.logger = ActiveSupport::Logger.new(log)

    events = captured_imgproxy_events do
      user_with_avatar.avatar.variant(resize_to_limit: [ 100, 100 ], format: :png).processed
    end

    assert_equal 1, events.size
    assert_equal true, events.first.payload[:fallback]
    assert_match(/RequestFailed/, events.first.payload[:error])
    assert_equal 1, log.string.scan("[activestorage-imgproxy]").size
    assert_match(/falling back to ActiveStorage::Transformers::/, log.string)
  ensure
    ActiveStorage.logger = ActiveSupport::Logger.new(IO::NULL)
  end

  def test_the_blob_is_only_in_scope_during_the_transformation
    assert_nil ActiveStorage::Imgproxy.current_blob

    seen = nil
    stub_imgproxy { seen = ActiveStorage::Imgproxy.current_blob; { status: 200, body: ImgproxyTestHelper::TRANSFORMED_PNG } }

    blob = user_with_avatar.avatar.blob
    blob.attachments.first.variant(resize_to_limit: [ 100, 100 ], format: :png).processed

    assert_equal blob, seen
    assert_nil ActiveStorage::Imgproxy.current_blob
  end

  def test_install_is_idempotent
    3.times { ActiveStorage::Imgproxy.install! }

    assert ActiveStorage::Imgproxy.installed?
    assert_equal 1, ActiveStorage::Variation.ancestors.count(ActiveStorage::Imgproxy::Ext::Variation)
    assert_equal 1, ActiveStorage::Variant.ancestors.count(ActiveStorage::Imgproxy::Ext::BlobTracking)
    assert_equal 1, ActiveStorage::VariantWithRecord.ancestors.count(ActiveStorage::Imgproxy::Ext::BlobTracking)
  end

  private
    def requested_url
      url = nil
      WebMock::RequestRegistry.instance.requested_signatures.each { |signature, _| url = signature.uri.to_s }
      url
    end

    def expected_signature(path)
      ActiveStorage::Imgproxy::UrlBuilder.new(ActiveStorage::Imgproxy.config).send(:sign, path)
    end

    def stock_transformer
      ActiveStorage::Variation.new(resize_to_limit: [ 100, 100 ]).send(:transformer)
    end

    # What Active Storage would have produced without this gem installed.
    def vanilla_variant_bytes(transformations)
      ActiveStorage::Imgproxy.config.enabled = false
      user_with_avatar.avatar.variant(transformations).processed.download
    ensure
      ActiveStorage::Imgproxy.reset_config!
    end
end
