# Query results kept across requests until the database changes.
#
# Rails' query cache lasts one request. This one keeps SELECT results in the process until any
# connection commits a write: the process's own writes move ReadCache.generation as they happen and
# when they commit, and other processes' commits show up as a change in PRAGMA data_version, read
# at the start of every request, job and cable action on a connection of its own that never
# writes. Every result is kept with the generation at which its read started, so a read that raced
# a commit is never served after it. Reads inside a transaction aren't cached: they may see its
# uncommitted writes.
#
# The generation also names the database's state for the response caches built on it.
module ReadCache
  MAX_ENTRIES = 5_000

  @generation = Concurrent::AtomicFixnum.new
  @entries = {}
  @mutex = Mutex.new

  class << self
    def generation
      @generation.value
    end

    def bump
      @generation.increment
    end

    def fetch(key)
      generation = self.generation
      if (entry = @mutex.synchronize { @entries[key] }) && entry.first == generation
        entry.last
      else
        yield.tap { |result| keep(key, generation, result) }
      end
    end

    # Moves the generation when a commit from another connection, in this process or another, has
    # changed the database since the last check.
    def check_for_commits
      version = data_version
      @mutex.synchronize do
        if version != @data_version
          @data_version = version
          bump
        end
      end
    end

    private
      def keep(key, generation, result)
        @mutex.synchronize do
          @entries.delete(key)
          @entries[key] = [ generation, result ]
          @entries.shift while @entries.size > MAX_ENTRIES
        end
      end

      def data_version
        @mutex.synchronize do
          if @connection_pid != Process.pid
            @connection = SQLite3::Database.new(ActiveRecord::Base.connection_db_config.database)
            @connection.busy_timeout = 5_000
            @connection_pid = Process.pid
          end
          @connection.get_first_value("PRAGMA data_version")
        end
      end
  end

  module Adapter
    WRITES = %i[ exec_query execute create insert update delete truncate truncate_tables exec_insert_all
      commit_db_transaction rollback_db_transaction rollback_to_savepoint restart_db_transaction ]

    WRITES.each do |method_name|
      define_method(method_name) do |*args, **options, &block|
        ReadCache.bump
        super(*args, **options, &block).tap { ReadCache.bump }
      end
    end

    def select_all(arel, name = nil, binds = [], preparable: nil, async: false, allow_retry: false)
      arel = arel_from_relation(arel)

      if async || transaction_open? || (arel.respond_to?(:locked) && arel.locked)
        super
      else
        sql, binds, preparable, allow_retry = to_sql_and_binds(arel, binds, preparable, allow_retry)
        key = binds.empty? ? sql : [ sql, binds.map { |bind| bind.respond_to?(:value_for_database) ? bind.value_for_database : bind } ]
        ReadCache.fetch(key) { super(sql, name, binds, preparable: preparable, allow_retry: allow_retry) }.dup
      end
    end
  end
end

ActiveSupport.on_load(:active_record_sqlite3adapter) { prepend ReadCache::Adapter }
Rails.application.executor.to_run { ReadCache.check_for_commits }
