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

      # It's Ruby, so we can only define a model after Sequel's established a
      # connection because it's all dynamic.
      if !River::Driver::Sequel.const_defined?(:RiverJob)
        River::Driver::Sequel.const_set(:RiverJob, Class.new(::Sequel::Model(:river_job)))

        # Since we only define our model once, take advantage of knowing this is
        # our first initialization to add required extensions.
        db.extension(:pg_array)
      end
    end

    def insert(insert_params)
      # the call to `#compact` is important so that we remove nils and table
      # default values get picked up instead
      to_job_row(
        RiverJob.create(
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
        )
      )
    end

    private def to_job_row(river_job)
      # needs to be accessed through values because Sequel shadows `errors`
      errors = river_job.values[:errors]

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
