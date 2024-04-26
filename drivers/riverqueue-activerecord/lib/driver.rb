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
        end)
      end
    end

    def insert(insert_params)
      # the call to `#compact` is important so that we remove nils and table
      # default values get picked up instead
      to_job_row(
        RiverJob.insert(
          {
            args: insert_params.encoded_args,
            kind: insert_params.kind,
            max_attempts: insert_params.max_attempts,
            priority: insert_params.priority,
            queue: insert_params.queue,
            state: insert_params.state,
            scheduled_at: insert_params.scheduled_at,
            tags: insert_params.tags
          }.compact,
          returning: Arel.sql("*")
        ).first
      )
    end

    # Type type injected to this method is not a `RiverJob`, but rather a raw
    # hash with stringified keys because we're inserting with the Arel framework
    # directly rather than generating a record from a model.
    private def to_job_row(raw_job)
      deserialize = ->(field) do
        RiverJob._default_attributes[field].type.deserialize(raw_job[field])
      end

      # Errors is `jsonb[]` so the subtype here will decode `jsonb`.
      errors_subtype = RiverJob._default_attributes["errors"].type.subtype

      River::JobRow.new(
        id: deserialize.call("id"),
        args: deserialize.call("args").yield_self { |a| a ? JSON.parse(a) : nil },
        attempt: deserialize.call("attempt"),
        attempted_at: deserialize.call("attempted_at"),
        attempted_by: deserialize.call("attempted_by"),
        created_at: deserialize.call("created_at"),
        errors: deserialize.call("errors")&.map do |e|
          deserialized_error = errors_subtype.deserialize(e)

          River::AttemptError.new(
            at: Time.parse(deserialized_error["at"]),
            attempt: deserialized_error["attempt"],
            error: deserialized_error["error"],
            trace: deserialized_error["trace"]
          )
        end,
        finalized_at: deserialize.call("finalized_at"),
        kind: deserialize.call("kind"),
        max_attempts: deserialize.call("max_attempts"),
        priority: deserialize.call("priority"),
        queue: deserialize.call("queue"),
        scheduled_at: deserialize.call("scheduled_at"),
        state: deserialize.call("state"),
        tags: deserialize.call("tags")
      )
    end
  end
end
