module River
  module Internal
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

      # TODO(brandur): Get these supported.
      # attr_accessor :unique
      # attr_accessor :unique_by_args
      # attr_accessor :unique_by_period
      # attr_accessor :unique_by_queue
      # attr_accessor :unique_by_state

      def initialize(
        encoded_args: nil,
        kind: nil,
        max_attempts: nil,
        priority: nil,
        queue: nil,
        scheduled_at: nil,
        state: nil,
        tags: nil
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
  private_constant :Internal
end
