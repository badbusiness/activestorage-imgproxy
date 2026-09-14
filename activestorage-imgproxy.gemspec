# frozen_string_literal: true

require_relative "lib/active_storage/imgproxy/version"

Gem::Specification.new do |spec|
  spec.name = "activestorage-imgproxy"
  spec.version = ActiveStorage::Imgproxy::VERSION
  spec.authors = [ "Bad Business" ]
  spec.summary = "Run Active Storage variant transformations on a shared imgproxy container"
  spec.description = <<~DESC.strip
    An Active Storage transformer that offloads image variant processing to a shared
    imgproxy service, keeping libvips memory spikes out of web and worker processes.
    Falls back to the stock Active Storage transformer on any error.
  DESC
  spec.homepage = "https://github.com/badbusiness/activestorage-imgproxy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # Not published to RubyGems; apps install it straight from GitHub.
  spec.metadata["allowed_push_host"] = "https://none.invalid"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = [ "lib" ]

  # Only 8.1 is actually tested (see .github/workflows/ci.yml). The hook sits on
  # two private methods of ActiveStorage::Variant and ActiveStorage::VariantWithRecord,
  # so the supported range must not claim more than CI proves.
  spec.add_dependency "activestorage", ">= 8.1", "< 9"
  spec.add_dependency "activesupport", ">= 8.1", "< 9"

  # base64 is a bundled gem from Ruby 3.4 on, and UrlBuilder needs it.
  spec.add_dependency "base64"
end
