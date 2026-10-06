# Forgery protection by the Sec-Fetch-Site header instead of tokens, as Rails main's
# `protect_from_forgery using: :header_only` does (the Rails this app pins doesn't have it).
# Browsers send the header with every request to a secure origin: same-origin and same-site writes
# pass, cross-site ones fail. A write without it passes only over plain HTTP, where browsers don't
# send it and the SameSite=Lax session cookie protects instead. The Origin check stays.
#
# Pages then carry no per-request token (see FormsHelper#token_tag), so they render the same until
# what they show changes.
module SameOriginForgeryProtection
  extend ActiveSupport::Concern

  private
    def verified_request?
      !protect_against_forgery? || request.get? || request.head? ||
        (valid_request_origin? && same_site_request?)
    end

    def same_site_request?
      case request.headers["Sec-Fetch-Site"]
      when "same-origin", "same-site" then true
      when nil then !request.ssl? && !Rails.application.config.force_ssl
      else false
      end
    end
end
