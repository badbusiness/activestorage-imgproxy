# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  include ImgproxyTestHelper

  def test_defaults_come_from_the_environment
    with_env("IMGPROXY_URL" => "http://imgproxy:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => "cd",
             "IMGPROXY_SOURCE_HOST" => "https://dashboard.hovetechniek.nl") do
      config = ActiveStorage::Imgproxy::Configuration.new

      assert_equal "http://imgproxy:8080", config.url
      assert_equal "ab", config.key
      assert_equal "cd", config.salt
      assert_equal "https://dashboard.hovetechniek.nl", config.source_host
      assert_equal 300, config.url_expires_in
      assert_equal 30, config.timeout
      assert config.enabled?
    end
  end

  def test_it_is_disabled_when_anything_is_missing
    with_env("IMGPROXY_URL" => nil, "IMGPROXY_KEY" => nil, "IMGPROXY_SALT" => nil) do
      refute_predicate ActiveStorage::Imgproxy::Configuration.new, :enabled?
    end

    with_env("IMGPROXY_URL" => "http://imgproxy:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => nil) do
      refute_predicate ActiveStorage::Imgproxy::Configuration.new, :enabled?
    end
  end

  def test_imgproxy_enabled_false_switches_it_off
    with_env("IMGPROXY_URL" => "http://imgproxy:8080", "IMGPROXY_KEY" => "ab", "IMGPROXY_SALT" => "cd",
             "IMGPROXY_ENABLED" => "false") do
      refute_predicate ActiveStorage::Imgproxy::Configuration.new, :enabled?
    end
  end

  def test_validate_names_what_is_missing
    config = ActiveStorage::Imgproxy::Configuration.new
    config.url = nil
    config.key = nil

    error = assert_raises(ActiveStorage::Imgproxy::MissingConfiguration) { config.validate! }
    assert_match(/IMGPROXY_URL/, error.message)
    assert_match(/IMGPROXY_KEY/, error.message)
  end

  def test_source_url_options_are_derived_from_source_host
    config = ActiveStorage::Imgproxy.config

    config.source_host = "https://dashboard.hovetechniek.nl"
    assert_equal({ protocol: "https", host: "dashboard.hovetechniek.nl" }, config.source_url_options)

    config.source_host = "http://localhost:3000"
    assert_equal({ protocol: "http", host: "localhost", port: 3000 }, config.source_url_options)

    config.source_host = nil
    assert_nil config.source_url_options
  end

  def test_a_source_host_without_a_host_is_rejected
    config = ActiveStorage::Imgproxy.config
    config.source_host = "dashboard.hovetechniek.nl"

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
