module RenderedOnceHelper
  RENDERED = Concurrent::Map.new

  # For markup that can't change while the process runs, such as the asset tags: the asset paths
  # are fixed at boot and there's no asset host or CSP nonce. The preload links a tag sends (the
  # stylesheets' Link header and early hints) are recorded with the markup and sent again each time.
  def rendered_once(name)
    if rendered = RENDERED[name]
      html, preload_links = rendered
      send_preload_links_header(preload_links)
      html
    else
      @recorded_preload_links = []
      html = yield.to_str.html_safe.freeze
      RENDERED[name] = [ html, @recorded_preload_links.freeze ]
      html
    end
  ensure
    @recorded_preload_links = nil
  end

  private
    def send_preload_links_header(preload_links, **)
      @recorded_preload_links&.concat(preload_links)
      super
    end
end
