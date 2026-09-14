# frozen_string_literal: true

require "test_helper"

class UrlBuilderTest < Minitest::Test
  include ImgproxyTestHelper

  BASE = ImgproxyTestHelper::IMGPROXY_URL

  # Test vector from https://docs.imgproxy.net/usage/signing_url
  # key "secret" (hex 736563726574), salt "hello" (hex 68656c6c6f).
  def test_signature_matches_the_documented_test_vector
    path = "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png"

    assert_equal "oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8", builder.send(:sign, path)
  end

  def test_builds_a_signed_base64_url
    url = builder.build(
      source_url: "http://example.com/images/curiosity.jpg",
      options: [ "rs:fill:300:400:0", "g:sm" ],
      extension: "png"
    )

    path = "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1wbGUuY29tL2ltYWdlcy9jdXJpb3NpdHkuanBn.png"
    assert_equal "#{BASE}/#{builder.send(:sign, path)}#{path}", url
  end

  def test_source_urls_with_query_strings_survive_base64_encoding
    source = "https://bucket.s3.eu-central-1.amazonaws.com/x/y?X-Amz-Signature=abc&X-Amz-Expires=300"
    url = builder.build(source_url: source, options: [], extension: "webp")

    encoded = url.split("/").last.delete_suffix(".webp")
    assert_equal source, Base64.urlsafe_decode64(encoded)
  end

  def test_omits_the_processing_options_segment_when_there_are_none
    url = builder.build(source_url: "http://example.com/a.jpg", options: [], extension: "png")

    assert_match %r{\A#{Regexp.escape(BASE)}/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\.png\z}, url
  end

  def test_a_trailing_slash_on_the_configured_url_does_not_double_up
    ActiveStorage::Imgproxy.config.url = "#{BASE}/"
    url = builder.build(source_url: "http://example.com/a.jpg", options: [], extension: "png")

    refute_includes url, "8080//"
  end

  # pack("H*") silently turns any string into bytes by reading the low nibble
  # of every character, so a typo would otherwise produce a well-formed
  # signature that imgproxy rejects with a 403 on every single variant.
  def test_a_non_hex_key_is_rejected
    [ "", "not-a-hex-key", "abc", "деадбееф" ].each do |value|
      ActiveStorage::Imgproxy.config.key = value

      assert_raises(ActiveStorage::Imgproxy::MissingConfiguration, "expected #{value.inspect} to be rejected") do
        builder.build(source_url: "http://example.com/a.jpg", options: [], extension: "png")
      end
    end
  end

  def test_a_non_hex_salt_is_rejected
    ActiveStorage::Imgproxy.config.salt = "not hex"

    assert_raises(ActiveStorage::Imgproxy::MissingConfiguration) do
      builder.build(source_url: "http://example.com/a.jpg", options: [], extension: "png")
    end
  end

  private
    def builder
      ActiveStorage::Imgproxy::UrlBuilder.new(ActiveStorage::Imgproxy.config)
    end
end
