require_relative "boot"

require "rails/all"

Bundler.require(*Rails.groups)

module Campfire
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.2
    config.active_support.isolation_level = :fiber

    # CAMPFIRE_CACHING=rust keeps only the caches the Rust port has: message fragments (Rails'
    # fragment cache and its per-process copy), gzip kept by body digest, Thruster's public-response
    # cache, prepared statements and static assets. It turns off the ones only the Elixir port has:
    # the cross-request read cache and the kept sidebar and messages pages. It's for measuring how
    # much those are worth.
    config.x.rust_caching_only = ENV["CAMPFIRE_CACHING"] == "rust"

    # Falcon's request bodies can't be rewound, and the bot API reads the raw body after Rack has
    # parsed it as a form. Puma's can.
    config.middleware.insert_before 0, Rack::RewindableInput::Middleware

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks rails_ext])

    # Fallback to English if translation key is missing
    config.i18n.fallbacks = true
  end
end
