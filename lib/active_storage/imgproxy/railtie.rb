# frozen_string_literal: true

require "rails/railtie"

module ActiveStorage
  module Imgproxy
    class Railtie < ::Rails::Railtie
      # Active Storage's models live in the engine's app/models and are
      # therefore reloadable, so the prepends are reapplied on every reload.
      # install! is idempotent, so this is cheap.
      config.to_prepare do
        ActiveStorage::Imgproxy.install!
      end
    end
  end
end
