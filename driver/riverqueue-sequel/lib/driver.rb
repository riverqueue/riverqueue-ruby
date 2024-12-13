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

    def job_get_by_id(id)
      data_set = @db[:river_job].where(id: id)
      data_set.first ? to_job_row(data_set.first) : nil
    end

    def job_insert(insert_params)
      job_insert_many([insert_params]).first
    end

    def job_insert_many(insert_params_array)
      @db[:river_job]
        .insert_conflict(
          target: [:unique_key],
          conflict_where: ::Sequel.lit(
            "unique_key IS NOT NULL AND unique_states IS NOT NULL AND river_job_state_in_bitmask(unique_states, state)"
          ),
          update: {kind: ::Sequel[:excluded][:kind]}
        )
        .returning(::Sequel.lit("*, (xmax != 0) AS unique_skipped_as_duplicate"))
        .multi_insert(insert_params_array.map { |p| insert_params_to_hash(p) })
        .map { |row| to_insert_result(row) }
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

    private def to_insert_result(result)
      [to_job_row(result), result[:unique_skipped_as_duplicate]]
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
        unique_key: river_job[:unique_key]&.to_s,
        unique_states: ::River::UniqueBitmask.to_states(river_job[:unique_states]&.to_i(2))
      )
    end
  end
end
