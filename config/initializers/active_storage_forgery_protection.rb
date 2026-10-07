# Active Storage's controllers check forgery with tokens, which pages no longer carry. They check
# Sec-Fetch-Site like the app's own controllers, as the Rust port's direct uploads do
# (crates/campfire/src/active_storage.rs, direct_uploads_create).
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.include SameOriginForgeryProtection
end
