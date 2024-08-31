module River::Driver
  # Provides a Sequel driver for River.
  #
  # Used in conjunction with a River client like:
  #
  #   DB = Sequel.connect("postgres://...")
  #   client = River::Client.new(River::Driver::Sequel.new(DB))
  #
  class Sequel
    def initialize(db)
      @db = db
      @db.extension(:pg_array)
      @db.extension(:pg_json)
    end

    def advisory_lock(key)
      @db.fetch("SELECT pg_advisory_xact_lock(?)", key).first
      nil
    end

    def advisory_lock_try(key)
      @db.fetch("SELECT pg_try_advisory_xact_lock(?)", key).first[:pg_try_advisory_xact_lock]
    end

    def job_get_by_id(id)
      data_set = @db[:river_job].where(id: id)
      data_set.first ? to_job_row(data_set.first) : nil
    end

    def job_get_by_kind_and_unique_properties(get_params)
      data_set = @db[:river_job].where(kind: get_params.kind)
      data_set = data_set.where(::Sequel.lit("tstzrange(?, ?, '[)') @> created_at", get_params.created_at[0], get_params.created_at[1])) if get_params.created_at
      data_set = data_set.where(args: get_params.encoded_args) if get_params.encoded_args
      data_set = data_set.where(queue: get_params.queue) if get_params.queue
      data_set = data_set.where(state: get_params.state) if get_params.state
      data_set.first ? to_job_row(data_set.first) : nil
    end

    def job_insert(insert_params)
      to_job_row(@db[:river_job].returning.insert_select(insert_params_to_hash(insert_params)))
    end

    def job_insert_unique(insert_params, unique_key)
      values = @db[:river_job]
        .insert_conflict(
          target: [:kind, :unique_key],
          conflict_where: ::Sequel.lit("unique_key IS NOT NULL"),
          update: {kind: ::Sequel[:excluded][:kind]}
        )
        .returning(::Sequel.lit("*, (xmax != 0) AS unique_skipped_as_duplicate"))
        .insert_select(
          insert_params_to_hash(insert_params).merge(unique_key: ::Sequel.blob(unique_key))
        )

      [to_job_row(values), values[:unique_skipped_as_duplicate]]
    end

    def job_insert_many(insert_params_many)
      @db[:river_job].multi_insert(insert_params_many.map { |p| insert_params_to_hash(p) })
      insert_params_many.count
    end

    def job_list
      data_set = @db[:river_job].order_by(:id)
      data_set.all.map { |job| to_job_row(job) }
    end

    def rollback_exception
      ::Sequel::Rollback
    end

    def transaction(&)
      @db.transaction(savepoint: true, &)
    end

    private def insert_params_to_hash(insert_params)
      # the call to `#compact` is important so that we remove nils and table
      # default values get picked up instead
      {
        args: insert_params.encoded_args,
        kind: insert_params.kind,
        max_attempts: insert_params.max_attempts,
        priority: insert_params.priority,
        queue: insert_params.queue,
        state: insert_params.state,
        scheduled_at: insert_params.scheduled_at,
        tags: insert_params.tags ? ::Sequel.pg_array(insert_params.tags) : nil
      }.compact
    end

    private def to_job_row(river_job)
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
        unique_key: river_job[:unique_key]&.to_s
      )
    end
  end
end
