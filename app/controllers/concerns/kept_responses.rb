# Keeps an action's finished response and serves it to requests with the same inputs instead of
# rendering again. Two keys, each with a counterpart in the Elixir port (basecamp/once-campfire-elixir):
#
# - render_kept: until the database changes. ReadCache.generation moves whenever any connection
#   commits. Elixir keeps the sidebar's HTML until one of the tables it reads changes
#   (lib/campfire/sidebar.ex); this is the same, invalidated by any table.
# - render_kept_for_etag: by the ETag fresh_when computed for this request, as Elixir keeps the
#   messages page per ETag (lib/campfire/messages.ex). The validators still run on every request;
#   an equal ETag means the same records at the same versions through the same template.
#
# Both also key on everything else a page reads from the request: the user, the URL, the format, the
# Turbo frame and the user agent. Before-actions (authentication, cookies) run on every request; only
# the render is skipped. Responses with a flash aren't kept. A kept response carries the headers the
# block set (content type, the stylesheets' Link header, fresh_when's validators), and otherwise the
# ETag Rack::ETag would compute from the body; Rack::ConditionalGet still answers revalidations with
# 304s. GzipCache gets the body's digest, so a kept page is compressed once.
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

  Kept = Data.define(:body, :digest, :headers)

  STORE = Store.new(128 * 1024 * 1024)

  private
    def render_kept(*inputs, &)
      render_kept_under(request_inputs(ReadCache.generation, *inputs), &)
    end

    def render_kept_for_etag(&)
      render_kept_under(request_inputs(response.etag), &)
    end

    def request_inputs(*inputs)
      [ controller_path, action_name, Current.user&.id, request.base_url, request.fullpath, request.format.to_s,
        request.headers["Turbo-Frame"], request.user_agent, *inputs ]
    end

    def render_kept_under(key)
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
      digest = Digest::SHA256.hexdigest(body).byteslice(0, 32)
      response.headers["ETag"] ||= %(W/"#{digest}")
      headers = response.headers.to_h.reject { |name, value| headers_before[name] == value }.except("set-cookie")
      kept = Kept.new(body:, digest:, headers: headers.freeze)

      if earlier && earlier.digest != kept.digest
        Rails.logger.error "Kept response differs from a fresh render: #{request.method} #{request.fullpath} (#{key.inspect})"
      end

      STORE[key] = kept
      request.env[GzipCache::DIGEST] = digest
    end

    def serve_kept(kept)
      kept.headers.each { |name, value| response.headers[name] = value }
      request.env[GzipCache::DIGEST] = kept.digest
      self.response_body = kept.body
    end
end
