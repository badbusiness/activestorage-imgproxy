# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

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

  # A 1x1 PNG, enough to prove the bytes came back from imgproxy untouched.
  TRANSFORMED_PNG = [
    "89504e470d0a1a0a0000000d4948445200000001000000010802000000907753",
    "de0000000c4944415408d763f8cf000001010100189ee1b90000000049454e44ae426082"
  ].join.then { |hex| [ hex ].pack("H*") }

  def setup
    super
    WebMock.disable_net_connect!
    ActiveStorage::Imgproxy.reset_config!
    ActiveStorage::Imgproxy.configure do |config|
      config.url = "http://imgproxy:8080"
      config.key = "736563726574"
      config.salt = "68656c6c6f"
      config.source_host = "http://dashboard.test"
      config.enabled = true
      config.timeout = 1
    end
    ActiveStorage::Imgproxy.install!
  end

  def teardown
    super
    WebMock.reset!
    ActiveStorage::Imgproxy.reset_config!
    User.delete_all
    ActiveStorage::Blob.delete_all
  end

  def user_with_avatar
    user = User.create!(name: "Martijn")
    user.avatar.attach(io: File.open(FIXTURE), filename: "sample.jpg", content_type: "image/jpeg")
    user
  end

  def stub_imgproxy(status: 200, body: TRANSFORMED_PNG, &block)
    stub = stub_request(:get, %r{\Ahttp://imgproxy:8080/})
    stub = block ? stub.to_return(&block) : stub.to_return(status: status, body: body)
    stub
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
end
