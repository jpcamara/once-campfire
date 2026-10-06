require "digest/md5"
require "zlib"

# Gzips the HTML and JSON a GET returns once per distinct body, and serves the kept bytes from then on.
#
# Pages render the same until what they show changes, so the same body goes out again and again;
# Thruster would compress it on every request. The compressed form is kept under a digest of the
# body (not the ETag, which for some pages is made from records rather than the bytes). Writes and
# public responses, which Thruster caches itself, are left to Thruster. The headers are
# Rack::Deflater's, which the stock app uses.
class GzipCache
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

    content = read(body)
    key = Digest::MD5.digest(content) << headers["content-type"]
    gzipped = @mutex.synchronize { @entries[key] } || keep(key, Zlib.gzip(content).freeze)

    headers["content-encoding"] = "gzip"
    headers["content-length"] = gzipped.bytesize.to_s
    headers["vary"] = [ headers["vary"], "Accept-Encoding" ].compact.join(",")
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
