require "active_support/cache/redis_cache_store"

# The Redis cache store, plus a copy of each fragment in the process that read or wrote it.
#
# A room page reads its ~50 message fragments from Redis on every request; fetching and
# deserializing them was about a third of the messages page. Fragment entries are versioned by
# their record's updated_at, so a process's copy of an entry is only used while it's still the
# version asked for, as with an entry read from Redis. Writes still go to Redis, so a fragment
# rendered by one process is read, not rendered again, by the others.
class FragmentCacheStore < ActiveSupport::Cache::RedisCacheStore
  class LocalCopies
    def initialize(max_entries)
      @max_entries = max_entries
      @entries = {}
      @mutex = Mutex.new
    end

    def [](key)
      @mutex.synchronize { @entries[key] }
    end

    def []=(key, entry)
      @mutex.synchronize do
        @entries.delete(key)
        @entries[key] = entry
        @entries.shift while @entries.size > @max_entries
      end
    end

    def delete(key)
      @mutex.synchronize { @entries.delete(key) }
    end
  end

  def initialize(local_entries: 10_000, **options)
    super(**options)
    @copies = LocalCopies.new(local_entries)
  end

  private
    def read_entry(key, **options)
      if entry = @copies[key]
        entry
      elsif entry = super
        keep_copy(key, entry)
      end
    end

    def read_multi_entries(names, **options)
      options = merged_options(options)
      keys = names.to_h { |name| [ name, normalize_key(name, options) ] }

      results = {}
      missing = names.reject do |name|
        entry = @copies[keys[name]]
        if entry && !entry.expired? && !entry.mismatched?(normalize_version(name, options))
          results[name] = entry.value
        end
      end

      results.merge!(read_multi_from_redis(missing, keys, options)) if missing.any?
      results
    end

    # RedisCacheStore#read_multi_entries, keeping the entries it reads.
    def read_multi_from_redis(names, keys, options)
      values = failsafe(:read_multi_entries, returning: {}) do
        redis.then { |c| c.mget(*names.map { |name| keys[name] }) }
      end

      names.zip(values).each_with_object({}) do |(name, value), results|
        if value && (entry = deserialize_entry(value))
          keep_copy(keys[name], entry)
          unless entry.expired? || entry.mismatched?(normalize_version(name, options))
            results[name] = entry.value
          end
        end
      end
    end

    def write_entry(key, entry, raw: false, **options)
      keep_copy(key, entry) unless raw
      super
    end

    def delete_entry(key, **options)
      @copies.delete(key)
      super
    end

    # Only HTML fragments: Jbuilder's cached hashes are merged into, and so can't be shared.
    def keep_copy(key, entry)
      if entry.value.is_a?(String)
        entry.value.freeze
        @copies[key] = entry
      end
      entry
    end
end
