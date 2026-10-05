module RenderedOnceHelper
  RENDERED = Concurrent::Map.new

  # For markup that can't change while the process runs, such as the asset tags: the asset paths
  # are fixed at boot and there's no asset host or CSP nonce.
  def rendered_once(name)
    RENDERED.compute_if_absent(name) { yield.to_str.html_safe.freeze }
  end
end
