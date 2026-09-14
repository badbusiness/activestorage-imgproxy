# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

# The gem reads its defaults from the environment, so a developer machine that
# happens to have IMGPROXY_* set must not be able to change what the suite sees.
ENV.keys.grep(/\AIMGPROXY_/).each { |key| ENV.delete(key) }

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "active_job/railtie"
require "active_storage/engine"

require "minitest/autorun"
require "active_support/testing/time_helpers"
require "webmock/minitest"

require "activestorage-imgproxy"

module Dummy
  STORAGE_ROOT = File.expand_path("../tmp/storage", __dir__)

  class Application < Rails::Application
    config.root = File.expand_path("../tmp/dummy", __dir__)
    config.eager_load = false
    config.secret_key_base = "a" * 64
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.active_record.sqlite3_adapter_strict_strings_by_default = true

    # Nothing may run in the background: the suite asserts on exactly which
    # service calls a transformation makes, and blob analysis downloads.
    config.active_job.queue_adapter = :test

    config.active_storage.service_configurations = {
      "local" => { "service" => "Disk", "root" => STORAGE_ROOT }
    }
    config.active_storage.service = :local
    config.active_storage.variant_processor = :vips
    # The variant record path adds nothing to what we are testing here and
    # keeps the schema smaller.
    config.active_storage.track_variants = false
  end
end

FileUtils.rm_rf(Dummy::STORAGE_ROOT)
FileUtils.mkdir_p(File.join(Dummy::Application.config.root, "config"))
File.write(File.join(Dummy::Application.config.root, "config/database.yml"), <<~YAML)
  test:
    adapter: sqlite3
    database: ":memory:"
YAML

Dummy::Application.initialize!

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :active_storage_blobs do |t|
    t.string :key, null: false
    t.string :filename, null: false
    t.string :content_type
    t.text :metadata
    t.string :service_name, null: false
    t.bigint :byte_size, null: false
    t.string :checksum
    t.datetime :created_at, null: false
    t.index [ :key ], unique: true
  end

  create_table :active_storage_attachments do |t|
    t.string :name, null: false
    t.references :record, null: false, polymorphic: true, index: false
    t.bigint :blob_id, null: false
    t.datetime :created_at, null: false
    t.index [ :record_type, :record_id, :name, :blob_id ], name: :index_asa_uniqueness, unique: true
  end

  create_table :active_storage_variant_records do |t|
    t.bigint :blob_id, null: false
    t.string :variation_digest, null: false
    t.index [ :blob_id, :variation_digest ], name: :index_asvr_uniqueness, unique: true
  end

  create_table :users do |t|
    t.string :name
  end
end

class User < ActiveRecord::Base
  has_one_attached :avatar
end

module ImgproxyTestHelper
  FIXTURE = File.expand_path("fixtures/sample.jpg", __dir__)
  IMGPROXY_URL = "http://imgproxy.test:8080"
  SOURCE_HOST = "http://app.example.com"

  # key "secret" (hex), salt "hello" (hex) -- the pair from the imgproxy
  # signing documentation, so the signature can be checked against its vector.
  KEY = "736563726574"
  SALT = "68656c6c6f"

  # A 1x1 PNG, enough to prove the bytes came back from imgproxy untouched.
  TRANSFORMED_PNG = [
    "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753",
    "de0000000c4944415408d763f8cf000001010100189ee1b90000000049454e44ae426082"
  ].join.then { |hex| [ hex ].pack("H*") }

  def setup
    super
    WebMock.disable_net_connect!
    configure_imgproxy!
    ActiveStorage::Imgproxy.install!
  end

  def teardown
    super
    WebMock.reset!
    ActiveStorage::Imgproxy.reset_config!
    User.delete_all
    ActiveStorage::Blob.delete_all
  end

  # Every value is set explicitly. reset_config! rebuilds from the environment,
  # which is exactly what a test must not depend on.
  def configure_imgproxy!
    ActiveStorage::Imgproxy.reset_config!
    ActiveStorage::Imgproxy.configure do |config|
      config.url = IMGPROXY_URL
      config.key = KEY
      config.salt = SALT
      config.source_host = SOURCE_HOST
      config.url_expires_in = 300
      config.open_timeout = 1
      config.timeout = 1
      config.max_bytes = ActiveStorage::Imgproxy::Configuration::DEFAULT_MAX_BYTES
      config.enabled = true
    end
  end

  def user_with_avatar
    user = User.create!(name: "Martijn")
    user.avatar.attach(io: File.open(FIXTURE), filename: "sample.jpg", content_type: "image/jpeg")
    user
  end

  def stub_imgproxy(status: 200, body: TRANSFORMED_PNG, &block)
    stub = stub_request(:get, %r{\A#{Regexp.escape(IMGPROXY_URL)}/})
    block ? stub.to_return(&block) : stub.to_return(status: status, body: body)
  end

  # The exact URL the gem is expected to request for this blob and variation.
  # Only deterministic under a frozen clock, because the signed source URL
  # carries an expiry.
  def expected_imgproxy_url(blob, transformations)
    variation = ActiveStorage::Variation.wrap(transformations)
    config = ActiveStorage::Imgproxy.config
    options = ActiveStorage::Imgproxy::Translator.new(variation.transformations.except(:format)).call

    source_url =
      begin
        previous = ActiveStorage::Current.url_options
        ActiveStorage::Current.url_options = config.source_url_options
        blob.url(expires_in: config.url_expires_in)
      ensure
        ActiveStorage::Current.url_options = previous
      end

    ActiveStorage::Imgproxy::UrlBuilder.new(config).build(
      source_url: source_url, options: options, extension: variation.format
    )
  end

  # minitest 6 no longer ships minitest/mock, and this is the one place the
  # suite has to inject a failure that the gem has no idea about.
  def with_exploding_client(message)
    original = ActiveStorage::Imgproxy.send(:remove_const, :Client)
    exploding = Class.new do
      define_method(:initialize) { |_config| raise message }
    end
    ActiveStorage::Imgproxy.const_set(:Client, exploding)
    yield
  ensure
    ActiveStorage::Imgproxy.send(:remove_const, :Client)
    ActiveStorage::Imgproxy.const_set(:Client, original)
  end

  def captured_imgproxy_events
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("transform.imgproxy") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Names of the Active Storage service calls made inside the block. Used to
  # prove that the imgproxy path never downloads the original.
  def captured_service_events
    names = []
    subscriber = ActiveSupport::Notifications.subscribe(/\.active_storage\z/) do |name, *|
      names << name
    end
    yield
    names
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
