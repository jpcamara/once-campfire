# The cookie session store, writing the cookie only when the session's data changed.
#
# With expire_after set, Rack rewrites (and so re-encrypts) the session cookie on every request that
# has a session, to roll its expiry forward. Here a request that only read the session, or never
# touched it, sends no cookie; one that changed it, reset it or dropped it does, as before.
class ChangedSessionCookieStore < ActionDispatch::Session::CookieStore
  LOADED = "campfire.session.loaded"
  RESET = "campfire.session.reset"

  def load_session(req)
    super.tap { |_id, data| req.set_header(LOADED, data.deep_dup) }
  end

  # reset_session loads the new, empty session again, which would otherwise count as unchanged.
  def delete_session(req, session_id, options)
    req.set_header(RESET, true)
    super
  end

  private
    def commit_session?(req, session, options)
      if options[:renew] || options[:drop] || req.get_header(RESET)
        super
      else
        session.loaded? && session.to_hash != req.get_header(LOADED) && super
      end
    end
end
