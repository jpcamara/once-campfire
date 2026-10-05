require "action_dispatch/middleware/static"

# ActionDispatch::Static probes up to nine paths on disk for every GET (the path, .html and
# /index.html, each also as .br and .gz) before handing the request to the app. public/ is fixed
# for the life of the process, so skip the probes when the path's first segment isn't in it.
module StaticFileIndex
  private
    def file_readable?(path)
      @top_level_entries ||= Dir.children(@root).to_set.freeze
      @top_level_entries.include?(path.b.delete_prefix("/").split("/", 2).first) && super
    end
end

ActionDispatch::FileHandler.prepend StaticFileIndex
