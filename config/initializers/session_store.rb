require_relative "../../lib/rails_ext/changed_session_cookie_store"

Rails.application.config.session_store ChangedSessionCookieStore,
  key: "_campfire_session",
  # Persist session cookie as permament so re-opened browser windows maintain a CSRF token
  expire_after: 20.years
