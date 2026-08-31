require "securerandom"

module River::Driver
  # Provides a Sequel driver for River that supports both PostgreSQL and SQLite.
  #
  # Used in conjunction with a River client like:
  #
  #   DB = Sequel.connect("postgres://...")
  #   client = River::Client.new(River::Driver::Sequel.new(DB))
  #
  # Or with SQLite:
  #
  #   DB = Sequel.connect("sqlite://path/to/river.db")
  #   client = River::Client.new(River::Driver::Sequel.new(DB))
  #
  class Sequel
    SQLITE_CONFLICT_WHERE = <<~SQL.chomp
      unique_key IS NOT NULL
          AND unique_states IS NOT NULL
          AND CASE state
            WHEN 'available' THEN unique_states & (1 << 0)
            WHEN 'cancelled' THEN unique_states & (1 << 1)
            WHEN 'completed' THEN unique_states & (1 << 2)
            WHEN 'discarded' THEN unique_states & (1 << 3)
            WHEN 'pending'   THEN unique_states & (1 << 4)
            WHEN 'retryable' THEN unique_states & (1 << 5)
            WHEN 'running'   THEN unique_states & (1 << 6)
            WHEN 'scheduled' THEN unique_states & (1 << 7)
            ELSE 0
          END >= 1
    SQL
    private_constant :SQLITE_CONFLICT_WHERE

    # SQLite 3.45+ may store JSON as binary JSONB. Always project JSON columns
    # through json() so this driver can read both the current JSONB format and
    # the text JSON used by River migrations through version 006. Cast times to
    # text so Sequel doesn't interpret timezone-less SQLite timestamps in the
    # process timezone.
    SQLITE_JOB_COLUMNS = <<~SQL.chomp
      id,
      json(args) AS args,
      attempt,
      CAST(attempted_at AS text) AS attempted_at,
      json(attempted_by) AS attempted_by,
      CAST(created_at AS text) AS created_at,
      json(errors) AS errors,
      CAST(finalized_at AS text) AS finalized_at,
      kind,
      max_attempts,
      json(metadata) AS metadata,
      priority,
      queue,
      state,
      CAST(scheduled_at AS text) AS scheduled_at,
      json(tags) AS tags,
      unique_key,
      unique_states
    SQL
    private_constant :SQLITE_JOB_COLUMNS

    SQLITE_UNIQUE_NONCE_KEY = "river:unique_nonce"
    private_constant :SQLITE_UNIQUE_NONCE_KEY

    def initialize(db)
      @db = db
      @is_sqlite = (db.database_type == :sqlite)

      unless @is_sqlite
        db.extension(:pg_array)
        db.extension(:pg_json)
      end
    end

    def job_get_by_id(id)
      if @is_sqlite
        row = sqlite_job_rows("WHERE id = ? LIMIT 1", id).first
        row ? sqlite_to_job_row_from_raw(row) : nil
      else
        data_set = @db[:river_job].where(id: id)
        data_set.first ? to_job_row(data_set.first) : nil
      end
    end

    def job_insert(insert_params)
      job_insert_many([insert_params]).first
    end

    def job_insert_many(insert_params_array)
      @is_sqlite ? sqlite_job_insert_many(insert_params_array) : postgres_job_insert_many(insert_params_array)
    end

    def job_list
      if @is_sqlite
        sqlite_job_rows("ORDER BY id").map { |row| sqlite_to_job_row_from_raw(row) }
      else
        @db[:river_job].order_by(:id).all.map { |job| to_job_row(job) }
      end
    end

    def rollback_exception
      ::Sequel::Rollback
    end

    def transaction(&)
      @db.transaction(savepoint: true, &)
    end

    private def postgres_job_insert_many(insert_params_array)
      @db[:river_job]
        .insert_conflict(
          target: [:unique_key],
          conflict_where: ::Sequel.lit(
            "unique_key IS NOT NULL AND unique_states IS NOT NULL AND river_job_state_in_bitmask(unique_states, state)"
          ),
          update: {kind: ::Sequel[:excluded][:kind]}
        )
        .returning(::Sequel.lit("*, (xmax != 0) AS unique_skipped_as_duplicate"))
        .multi_insert(insert_params_array.map { |p| postgres_insert_params_to_hash(p) })
        .map { |row| [to_job_row(row), row[:unique_skipped_as_duplicate]] }
    end

    # River's current SQLite driver uses json_each to make a batch a single,
    # atomic statement. The JSON columns are converted to SQLite JSONB here,
    # matching migration 007 and newer River databases.
    private def sqlite_job_insert_many(insert_params_array)
      return [] if insert_params_array.empty?

      @db.transaction(savepoint: true) do
        nonce = SecureRandom.hex(8)
        jobs = insert_params_array.map { |param| sqlite_insert_params_to_hash(param, nonce) }

        sql = <<~SQL
          INSERT INTO river_job (
            args,
            created_at,
            kind,
            max_attempts,
            metadata,
            priority,
            queue,
            scheduled_at,
            state,
            tags,
            unique_key,
            unique_states
          )
          SELECT
            jsonb(json_extract(value, '$.args')),
            datetime('now', 'subsec'),
            cast(json_extract(value, '$.kind') AS text),
            cast(json_extract(value, '$.max_attempts') AS integer),
            jsonb(json_extract(value, '$.metadata')),
            cast(json_extract(value, '$.priority') AS integer),
            cast(json_extract(value, '$.queue') AS text),
            coalesce(cast(json_extract(value, '$.scheduled_at') AS text), datetime('now', 'subsec')),
            cast(json_extract(value, '$.state') AS text),
            jsonb(json_extract(value, '$.tags')),
            CASE
              WHEN length(cast(json_extract(value, '$.unique_key') AS text)) = 0 THEN NULL
              ELSE unhex(cast(json_extract(value, '$.unique_key') AS text))
            END,
            nullif(cast(json_extract(value, '$.unique_states') AS integer), 0)
          FROM json_each(cast(? AS blob))
          WHERE true
          ON CONFLICT (unique_key) WHERE #{SQLITE_CONFLICT_WHERE}
          DO UPDATE SET kind = EXCLUDED.kind
          RETURNING #{SQLITE_JOB_COLUMNS}
        SQL

        rows = @db.fetch(sql, JSON.dump(jobs)).all
        sqlite_notify_insert(insert_params_array)

        rows.map do |row|
          metadata = JSON.parse(row[:metadata])
          [sqlite_to_job_row_from_raw(row), metadata[SQLITE_UNIQUE_NONCE_KEY] != nonce]
        end
      end
    end

    private def postgres_insert_params_to_hash(insert_params)
      {
        args: insert_params.encoded_args,
        kind: insert_params.kind,
        max_attempts: insert_params.max_attempts,
        priority: insert_params.priority,
        queue: insert_params.queue,
        state: insert_params.state,
        scheduled_at: insert_params.scheduled_at,
        tags: ::Sequel.pg_array(insert_params.tags || [], :text),
        unique_key: insert_params.unique_key ? ::Sequel.blob(insert_params.unique_key) : nil,
        unique_states: insert_params.unique_states
      }
    end

    private def sqlite_insert_params_to_hash(insert_params, nonce)
      {
        args: JSON.parse(insert_params.encoded_args),
        kind: insert_params.kind,
        max_attempts: insert_params.max_attempts,
        metadata: {SQLITE_UNIQUE_NONCE_KEY => nonce},
        priority: insert_params.priority,
        queue: insert_params.queue,
        scheduled_at: insert_params.scheduled_at ? format_time(insert_params.scheduled_at) : nil,
        state: insert_params.state,
        tags: insert_params.tags || [],
        unique_key: insert_params.unique_key&.unpack1("H*"),
        unique_states: insert_params.unique_states&.to_i(2)
      }
    end

    private def to_job_row(river_job)
      if @is_sqlite
        row = sqlite_job_rows("WHERE id = ? LIMIT 1", river_job[:id]).first
        sqlite_to_job_row_from_raw(row)
      else
        postgres_to_job_row(river_job)
      end
    end

    private def postgres_to_job_row(river_job)
      River::JobRow.new(
        id: river_job[:id],
        args: river_job[:args].to_h,
        attempt: river_job[:attempt],
        attempted_at: river_job[:attempted_at]&.getutc,
        attempted_by: river_job[:attempted_by],
        created_at: river_job[:created_at].getutc,
        errors: river_job[:errors]&.map { |deserialized_error|
          River::AttemptError.new(
            at: Time.parse(deserialized_error["at"]),
            attempt: deserialized_error["attempt"],
            error: deserialized_error["error"],
            trace: deserialized_error["trace"]
          )
        },
        finalized_at: river_job[:finalized_at]&.getutc,
        kind: river_job[:kind],
        max_attempts: river_job[:max_attempts],
        metadata: river_job[:metadata],
        priority: river_job[:priority],
        queue: river_job[:queue],
        scheduled_at: river_job[:scheduled_at].getutc,
        state: river_job[:state],
        tags: river_job[:tags].to_a,
        unique_key: river_job[:unique_key]&.to_s,
        unique_states: ::River::UniqueBitmask.to_states(river_job[:unique_states]&.to_i(2))
      )
    end

    private def sqlite_to_job_row_from_raw(river_job)
      errors = river_job[:errors] ? JSON.parse(river_job[:errors]) : []

      River::JobRow.new(
        id: river_job[:id],
        args: JSON.parse(river_job[:args]),
        attempt: river_job[:attempt],
        attempted_at: parse_sqlite_time(river_job[:attempted_at]),
        attempted_by: river_job[:attempted_by] ? JSON.parse(river_job[:attempted_by]) : nil,
        created_at: parse_sqlite_time(river_job[:created_at]),
        errors: errors.map { |deserialized_error|
          River::AttemptError.new(
            at: Time.parse(deserialized_error["at"]),
            attempt: deserialized_error["attempt"],
            error: deserialized_error["error"],
            trace: deserialized_error["trace"]
          )
        },
        finalized_at: parse_sqlite_time(river_job[:finalized_at]),
        kind: river_job[:kind],
        max_attempts: river_job[:max_attempts],
        metadata: JSON.parse(river_job[:metadata]),
        priority: river_job[:priority],
        queue: river_job[:queue],
        scheduled_at: parse_sqlite_time(river_job[:scheduled_at]),
        state: river_job[:state],
        tags: JSON.parse(river_job[:tags]),
        unique_key: river_job[:unique_key]&.to_s,
        unique_states: river_job[:unique_states] ? ::River::UniqueBitmask.to_states(river_job[:unique_states]) : nil
      )
    end

    private def format_time(time)
      time.getutc.round(3).strftime("%Y-%m-%d %H:%M:%S.%3N")
    end

    private def parse_sqlite_time(value)
      return nil unless value

      value = value.to_s
      value += " UTC" unless value.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/)
      Time.parse(value).utc
    end

    private def sqlite_job_rows(suffix, *binds)
      @db.fetch("SELECT #{SQLITE_JOB_COLUMNS} FROM river_job #{suffix}", *binds).all
    end

    private def sqlite_notify_insert(insert_params_array)
      queues = insert_params_array
        .select { |param| param.state == ::River::JOB_STATE_AVAILABLE }
        .map(&:queue)
        .uniq
      return if queues.empty?

      @db[:river_notification].multi_insert(queues.map do |queue|
        {payload: JSON.dump({queue: queue}), topic: "insert"}
      end)
    end
  end
end
