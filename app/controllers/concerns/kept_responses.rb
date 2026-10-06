# Keeps an action's finished response until the database changes, and serves it to requests with
# the same inputs instead of rendering again.
#
# Before-actions (authentication, cookies) still run on every request; only the render is skipped.
# The key is ReadCache.generation, which moves whenever any connection commits, plus everything else
# a page reads from the request: the user, the base URL, the format, the Turbo frame, the user agent
# and what the action passes in. Responses with a flash aren't kept. The kept response carries the
# headers its render added (content type, the stylesheets' Link header) and the ETag Rack::ETag
# would have computed from the body; GzipCache gets its digest, so a kept page is compressed once.
#
# With CAMPFIRE_CHECK_CACHES=1 every hit renders anyway and logs any difference from what was kept.
module KeptResponses
  extend ActiveSupport::Concern

  CHECK = ENV["CAMPFIRE_CHECK_CACHES"].present?

  class Store
    def initialize(max_bytes)
      @max_bytes, @bytes = max_bytes, 0
      @entries = {}
      @mutex = Mutex.new
    end

    def [](key)
      @mutex.synchronize { @entries[key] }
    end

    def []=(key, kept)
      @mutex.synchronize do
        @bytes -= @entries.delete(key)&.body&.bytesize.to_i
        @entries[key] = kept
        @bytes += kept.body.bytesize
        while @bytes > @max_bytes
          _, evicted = @entries.shift
          @bytes -= evicted.body.bytesize
        end
      end
    end
  end

  Kept = Data.define(:body, :etag, :headers)

  STORE = Store.new(128 * 1024 * 1024)

  private
    def render_kept(*inputs)
      key = [ controller_path, action_name, ReadCache.generation, Current.user&.id, request.base_url,
        request.format.to_s, request.headers["Turbo-Frame"], request.user_agent, *inputs ]

      if !flash.empty?
        yield
      elsif (kept = STORE[key]) && !CHECK
        serve_kept(kept)
      else
        keep_rendered(key, kept) { yield }
      end
    end

    def keep_rendered(key, earlier)
      headers_before = response.headers.to_h
      yield
      return unless response.status == 200 && flash.empty?

      body = response.body.freeze
      etag = %(W/"#{Digest::SHA256.hexdigest(body).byteslice(0, 32)}")
      headers = response.headers.to_h.reject { |name, value| headers_before[name] == value }.except("set-cookie")
      kept = Kept.new(body:, etag:, headers: headers.freeze)

      if earlier && earlier.etag != kept.etag
        Rails.logger.error "Kept response differs from a fresh render: #{request.method} #{request.fullpath} (#{key.inspect})"
      end

      STORE[key] = kept
      response.headers["ETag"] = etag
      request.env[GzipCache::DIGEST] = etag
    end

    def serve_kept(kept)
      kept.headers.each { |name, value| response.headers[name] = value }
      response.headers["ETag"] = kept.etag
      request.env[GzipCache::DIGEST] = kept.etag
      self.response_body = kept.body
    end
end
