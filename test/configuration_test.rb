# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  include ImgproxyTestHelper

  def test_defaults_come_from_the_environment
    with_env("IMGPROXY_URL" => "http://imgproxy.test:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => "cd",
             "IMGPROXY_SOURCE_HOST" => "https://app.example.com") do
      config = ActiveStorage::Imgproxy::Configuration.new

      assert_equal "http://imgproxy.test:8080", config.url
      assert_equal "ab", config.key
      assert_equal "cd", config.salt
      assert_equal "https://app.example.com", config.source_host
      assert_equal 300, config.url_expires_in
      assert_equal 2, config.open_timeout
      assert_equal 10, config.timeout
      assert_equal 64 * 1024 * 1024, config.max_bytes
      assert config.enabled?
    end
  end

  def test_the_timeouts_can_be_tuned_from_the_environment
    with_env("IMGPROXY_URL" => "http://imgproxy.test:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => "cd",
             "IMGPROXY_OPEN_TIMEOUT" => "1", "IMGPROXY_TIMEOUT" => "5", "IMGPROXY_MAX_BYTES" => "1024") do
      config = ActiveStorage::Imgproxy::Configuration.new

      assert_equal 1, config.open_timeout
      assert_equal 5, config.timeout
      assert_equal 1024, config.max_bytes
    end
  end

  def test_a_non_numeric_value_falls_back_to_the_default_with_a_warning
    log = StringIO.new
    ActiveStorage.logger = ActiveSupport::Logger.new(log)

    with_env("IMGPROXY_TIMEOUT" => "10s", "IMGPROXY_MAX_BYTES" => "64MB") do
      config = ActiveStorage::Imgproxy::Configuration.new

      assert_equal 10, config.timeout
      assert_equal 64 * 1024 * 1024, config.max_bytes
    end

    assert_match(/IMGPROXY_TIMEOUT is not a number/, log.string)
    assert_match(/IMGPROXY_MAX_BYTES is not a number/, log.string)
  ensure
    ActiveStorage.logger = ActiveSupport::Logger.new(IO::NULL)
  end

  def test_it_is_disabled_when_anything_is_missing
    with_env("IMGPROXY_URL" => nil, "IMGPROXY_KEY" => nil, "IMGPROXY_SALT" => nil) do
      refute_predicate ActiveStorage::Imgproxy::Configuration.new, :enabled?
    end

    with_env("IMGPROXY_URL" => "http://imgproxy.test:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => nil) do
      refute_predicate ActiveStorage::Imgproxy::Configuration.new, :enabled?
    end
  end

  def test_imgproxy_enabled_false_switches_it_off
    with_env("IMGPROXY_URL" => "http://imgproxy.test:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => "cd",
             "IMGPROXY_ENABLED" => "false") do
      refute_predicate ActiveStorage::Imgproxy::Configuration.new, :enabled?
    end
  end

  # An app that asked Active Storage for no image processing at all must not
  # get it anyway through this gem.
  def test_it_is_disabled_when_active_storage_has_variants_disabled
    previous = ActiveStorage.variant_transformer
    ActiveStorage.variant_transformer = ActiveStorage::Transformers::NullTransformer

    refute_predicate ActiveStorage::Imgproxy.config, :enabled?
  ensure
    ActiveStorage.variant_transformer = previous
  end

  def test_validate_names_what_is_missing
    config = ActiveStorage::Imgproxy::Configuration.new
    config.url = nil
    config.key = nil

    error = assert_raises(ActiveStorage::Imgproxy::MissingConfiguration) { config.validate! }
    assert_match(/IMGPROXY_URL/, error.message)
    assert_match(/IMGPROXY_KEY/, error.message)
  end

  def test_validate_rejects_a_key_or_salt_that_is_not_hex
    config = ActiveStorage::Imgproxy.config
    config.key = "not-a-hex-key"

    error = assert_raises(ActiveStorage::Imgproxy::MissingConfiguration) { config.validate! }
    assert_match(/hex encoded/, error.message)
    assert_match(/IMGPROXY_KEY/, error.message)
    refute_match(/IMGPROXY_SALT/, error.message)
  end

  def test_validate_rejects_an_odd_number_of_hex_digits
    config = ActiveStorage::Imgproxy.config
    config.salt = "abc"

    assert_raises(ActiveStorage::Imgproxy::MissingConfiguration) { config.validate! }
  end

  def test_source_url_options_are_derived_from_source_host
    config = ActiveStorage::Imgproxy.config

    config.source_host = "https://app.example.com"
    assert_equal({ protocol: "https", host: "app.example.com" }, config.source_url_options)

    config.source_host = "http://localhost:3000"
    assert_equal({ protocol: "http", host: "localhost", port: 3000 }, config.source_url_options)

    config.source_host = nil
    assert_nil config.source_url_options
  end

  def test_a_source_host_without_a_host_is_rejected
    config = ActiveStorage::Imgproxy.config
    config.source_host = "app.example.com"

    assert_raises(ActiveStorage::Imgproxy::MissingConfiguration) { config.source_url_options }
  end

  private
    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
end
