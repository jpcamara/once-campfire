require "digest/sha2"
require "zlib"

# Gzips the HTML and JSON a GET returns once per distinct body, and serves the kept bytes from then on.
#
# Pages render the same until what they show changes, so the same body goes out again and again, and
# Rack::Deflater (in config.ru, as in the stock app) would compress it on every request. This sits
# inside it: it hands Deflater these responses already compressed, with the headers Deflater gives
# them, and Deflater compresses everything else as before. The compressed form is kept under a digest
# of the body (not the ETag, which for some pages is made from records rather than the bytes). An app
# that already knows its body's digest (a kept response's ETag) hands it over in env[DIGEST] instead.
class GzipCache
  DIGEST = "campfire.body_digest"
  COMPRESSIBLE = %r{\A(text/html|text/vnd\.turbo-stream\.html|application/json)\b}

  def initialize(app, max_bytes: 64 * 1024 * 1024)
    @app = app
    @max_bytes = max_bytes
    @entries = {}
    @bytes = 0
    @mutex = Mutex.new
  end

  def call(env)
    status, headers, body = response = @app.call(env)
    return response unless compress?(env, status, headers)

    if (digest = env[DIGEST]) && (gzipped = kept("#{digest} #{headers["content-type"]}"))
      body.close if body.respond_to?(:close)
    else
      content = read(body)
      key = "#{digest || Digest::SHA256.digest(content)} #{headers["content-type"]}"
      gzipped = kept(key) || keep(key, Zlib.gzip(content).freeze)
    end

    vary = headers["vary"].to_s.split(",").map(&:strip)
    headers["vary"] = vary.push("Accept-Encoding").join(",") unless vary.any? { |v| v == "*" || v.casecmp?("accept-encoding") }
    headers["content-encoding"] = "gzip"
    headers.delete("content-length")
    [ status, headers, [ gzipped ] ]
  end

  private
    def compress?(env, status, headers)
      env["REQUEST_METHOD"] == "GET" && status == 200 && COMPRESSIBLE.match?(headers["content-type"]) &&
        !headers["content-encoding"] && !headers["cache-control"].to_s.match?(/public|no-transform/) &&
        Rack::Utils.select_best_encoding(%w[ gzip identity ], Rack::Request.new(env).accept_encoding) == "gzip"
    end

    def read(body)
      content = +""
      body.each { |part| content << part }
      content
    ensure
      body.close if body.respond_to?(:close)
    end

    def kept(key)
      @mutex.synchronize { @entries[key] }
    end

    def keep(key, gzipped)
      @mutex.synchronize do
        return @entries[key] if @entries.key?(key)

        @entries[key] = gzipped
        @bytes += gzipped.bytesize
        while @bytes > @max_bytes
          _, evicted = @entries.shift
          @bytes -= evicted.bytesize
        end
      end
      gzipped
    end
end
