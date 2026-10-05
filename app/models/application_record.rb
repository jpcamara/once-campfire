class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  class << self
    def utc_database?
      @utc_database = with_connection(&:default_timezone) == :utc if @utc_database.nil?
      @utc_database
    end
  end

  private
    # Active Record's own check, except that it checks out a connection on every call to read the
    # database's time zone (see the FIXME there). The time zone comes from configuration, so read it
    # once per class. Cache keys of every fragment-cached record went through this.
    def can_use_fast_cache_version?(timestamp)
      timestamp.is_a?(String) &&
        cache_timestamp_format == :usec &&
        self.class.utc_database? &&
        !updated_at_came_from_user?
    end
end
