module River
  # Contains an interface used by the top-level River module to interface with
  # its driver implementations. All types and methods in this module should be
  # considered to be for internal use only and subject to change. API stability
  # is not guaranteed.
  module Driver
    # Parameters for looking up a job by kind and unique properties.
    class JobGetByKindAndUniquePropertiesParam
      attr_accessor :created_at
      attr_accessor :encoded_args
      attr_accessor :kind
      attr_accessor :queue
      attr_accessor :state

      def initialize(
        kind:,
        created_at: nil,
        encoded_args: nil,
        queue: nil,
        state: nil
      )
        self.kind = kind
        self.created_at = created_at
        self.encoded_args = encoded_args
        self.queue = queue
        self.state = state
      end
    end

    # Insert parameters for a job. This is sent to underlying drivers and is meant
    # for internal use only. Its interface is subject to change.
    class JobInsertParams
      attr_accessor :encoded_args
      attr_accessor :kind
      attr_accessor :max_attempts
      attr_accessor :priority
      attr_accessor :queue
      attr_accessor :scheduled_at
      attr_accessor :state
      attr_accessor :tags

      def initialize(
        encoded_args:,
        kind:,
        max_attempts:,
        priority:,
        queue:,
        scheduled_at:,
        state:,
        tags:
      )
        self.encoded_args = encoded_args
        self.kind = kind
        self.max_attempts = max_attempts
        self.priority = priority
        self.queue = queue
        self.scheduled_at = scheduled_at
        self.state = state
        self.tags = tags
      end
    end
  end
end
