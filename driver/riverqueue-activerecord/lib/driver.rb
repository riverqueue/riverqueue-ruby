module River::Driver
  # Provides a ActiveRecord driver for River.
  #
  # Used in conjunction with a River client like:
  #
  #   DB = ActiveRecord.connect("postgres://...")
  #   client = River::Client.new(River::Driver::ActiveRecord.new(DB))
  #
  class ActiveRecord
    def initialize
      # It's Ruby, so we can only define a model after ActiveRecord's established a
      # connection because it's all dynamic.
      if !River::Driver::ActiveRecord.const_defined?(:RiverJob)
        River::Driver::ActiveRecord.const_set(:RiverJob, Class.new(::ActiveRecord::Base) do
          self.table_name = "river_job"

          # Unfortunately, Rails errors if you have a column called `errors` and
          # provides no way to remap names (beyond ignoring a column, which we
          # really don't want). This patch is in place so we can hydrate this
          # model at all without ActiveRecord self-immolating.
          def self.dangerous_attribute_method?(method_name)
            return false if method_name == "errors"
            super
          end

          # See comment above, but since we force allowed `errors` as an
          # attribute name, ActiveRecord would otherwise fail to save a row as
          # it checked for its own `errors` hash and finding no values.
          def errors = {}
        end)
      end
    end

    def job_get_by_id(id)
      data_set = RiverJob.where(id: id)
      data_set.first ? to_job_row_from_model(data_set.first) : nil
    end

    def job_insert(insert_params)
      job_insert_many([insert_params]).first
    end

    def job_insert_many(insert_params_many)
      res = RiverJob.upsert_all(
        insert_params_many.map { |param| insert_params_to_hash(param) },
        on_duplicate: Arel.sql("kind = EXCLUDED.kind"),
        returning: Arel.sql("*, (xmax != 0) AS unique_skipped_as_duplicate"),

        # It'd be nice to specify this as `(kind, unique_key) WHERE unique_key
        # IS NOT NULL` like we do elsewhere, but in its pure ingenuity, fucking
        # ActiveRecord tries to look up a unique index instead of letting
        # Postgres handle that, and of course it doesn't support a `WHERE`
        # clause. The workaround is to target the index name instead of columns.
        unique_by: "river_job_unique_idx"
      )
      to_insert_results(res)
    end

    def job_list
      data_set = RiverJob.order(:id)
      data_set.all.map { |job| to_job_row_from_model(job) }
    end

    def rollback_exception
      ::ActiveRecord::Rollback
    end

    def transaction(&)
      ::ActiveRecord::Base.transaction(requires_new: true, &)
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
        tags: insert_params.tags || [],
        unique_key: insert_params.unique_key,
        unique_states: insert_params.unique_states
      }
    end

    private def to_job_row_from_model(river_job)
      # needs to be accessed through values because `errors` is shadowed by both
      # ActiveRecord and the patch above
      errors = river_job.attributes["errors"]

      River::JobRow.new(
        id: river_job.id,
        args: JSON.parse(river_job.args),
        attempt: river_job.attempt,
        attempted_at: river_job.attempted_at&.getutc,
        attempted_by: river_job.attempted_by,
        created_at: river_job.created_at.getutc,
        errors: errors&.map { |e|
          deserialized_error = JSON.parse(e, symbolize_names: true)

          River::AttemptError.new(
            at: Time.parse(deserialized_error[:at]),
            attempt: deserialized_error[:attempt],
            error: deserialized_error[:error],
            trace: deserialized_error[:trace]
          )
        },
        finalized_at: river_job.finalized_at&.getutc,
        kind: river_job.kind,
        max_attempts: river_job.max_attempts,
        metadata: river_job.metadata,
        priority: river_job.priority,
        queue: river_job.queue,
        scheduled_at: river_job.scheduled_at.getutc,
        state: river_job.state,
        tags: river_job.tags,
        unique_key: river_job.unique_key,
        unique_states: river_job.unique_states
      )
    end

    private def to_insert_results(res)
      res.rows.map do |row|
        to_job_row_from_raw(row, res.columns, res.column_types)
      end
    end

    # This is really awful, but some of ActiveRecord's methods (e.g. `.create`)
    # return a model, and others (e.g. `.upsert`) return raw values, and
    # therefore this second version from unmarshaling a job row exists. I
    # searched long and hard for a way to have the former type of method return
    # raw or the latter type of method return a model, but was unable to find
    # anything.
    private def to_job_row_from_raw(row, columns, column_types)
      river_job = {}

      row.each_with_index do |val, i|
        river_job[columns[i]] = column_types[i].deserialize(val)
      end

      errors = river_job["errors"]&.map do |e|
        deserialized_error = JSON.parse(e)

        River::AttemptError.new(
          at: Time.parse(deserialized_error["at"]),
          attempt: deserialized_error["attempt"],
          error: deserialized_error["error"],
          trace: deserialized_error["trace"]
        )
      end

      [
        River::JobRow.new(
          id: river_job["id"],
          args: JSON.parse(river_job["args"]),
          attempt: river_job["attempt"],
          attempted_at: river_job["attempted_at"]&.getutc,
          attempted_by: river_job["attempted_by"],
          created_at: river_job["created_at"].getutc,
          errors: errors,
          finalized_at: river_job["finalized_at"]&.getutc,
          kind: river_job["kind"],
          max_attempts: river_job["max_attempts"],
          metadata: river_job["metadata"],
          priority: river_job["priority"],
          queue: river_job["queue"],
          scheduled_at: river_job["scheduled_at"].getutc,
          state: river_job["state"],
          tags: river_job["tags"],
          unique_key: river_job["unique_key"],
          unique_states: ::River::UniqueBitmask.to_states(river_job["unique_states"]&.to_i(2))
        ),
        river_job["unique_skipped_as_duplicate"]
      ]
    end
  end
end
