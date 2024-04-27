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

    def insert(insert_params)
      to_job_row(RiverJob.create(insert_params_to_hash(insert_params)))
    end

    def insert_many(insert_params_many)
      RiverJob.insert_all(insert_params_many.map { |p| insert_params_to_hash(p) })
      insert_params_many.count
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
        tags: insert_params.tags
      }.compact
    end

    # Type type injected to this method is not a `RiverJob`, but rather a raw
    # hash with stringified keys because we're inserting with the Arel framework
    # directly rather than generating a record from a model.
    private def to_job_row(river_job)
      # needs to be accessed through values because `errors` is shadowed by both
      # ActiveRecord and the patch above
      errors = river_job.attributes["errors"]

      River::JobRow.new(
        id: river_job.id,
        args: river_job.args ? JSON.parse(river_job.args) : nil,
        attempt: river_job.attempt,
        attempted_at: river_job.attempted_at,
        attempted_by: river_job.attempted_by,
        created_at: river_job.created_at,
        errors: errors&.map { |e|
          deserialized_error = JSON.parse(e, symbolize_names: true)

          River::AttemptError.new(
            at: Time.parse(deserialized_error[:at]),
            attempt: deserialized_error[:attempt],
            error: deserialized_error[:error],
            trace: deserialized_error[:trace]
          )
        },
        finalized_at: river_job.finalized_at,
        kind: river_job.kind,
        max_attempts: river_job.max_attempts,
        priority: river_job.priority,
        queue: river_job.queue,
        scheduled_at: river_job.scheduled_at,
        state: river_job.state,
        tags: river_job.tags
      )
    end
  end
end
