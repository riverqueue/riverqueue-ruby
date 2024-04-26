module River
  class InsertOpts
    # MaxAttempts is the maximum number of total attempts (including both the
    # original run and all retries) before a job is abandoned and set as
    # discarded.
    attr_accessor :max_attempts

    # Priority is the priority of the job, with 1 being the highest priority and
    # 4 being the lowest. When fetching available jobs to work, the highest
    # priority jobs will always be fetched before any lower priority jobs are
    # fetched. Note that if your workers are swamped with more high-priority jobs
    # then they can handle, lower priority jobs may not be fetched.
    #
    # Defaults to PRIORITY_DEFAULT.
    attr_accessor :priority

    # Queue is the name of the job queue in which to insert the job.
    #
    # Defaults to QUEUE_DEFAULT.
    attr_accessor :queue

    # ScheduledAt is a time in future at which to schedule the job (i.e. in
    # cases where it shouldn't be run immediately). The job is guaranteed not
    # to run before this time, but may run slightly after depending on the
    # number of other scheduled jobs and how busy the queue is.
    #
    # Use of this option generally only makes sense when passing options into
    # Insert rather than when a job args is returning `#insert_opts`, however,
    # it will work in both cases.
    attr_accessor :scheduled_at

    # Tags are an arbitrary list of keywords to add to the job. They have no
    # functional behavior and are meant entirely as a user-specified construct
    # to help group and categorize jobs.
    #
    # If tags are specified from both a job args override and from options on
    # Insert, the latter takes precedence. Tags are not merged.
    attr_accessor :tags

    # UniqueOpts returns options relating to job uniqueness. An empty struct
    # avoids setting any worker-level unique options.
    #
    # TODO: Implement.
    attr_accessor :unique_opts

    def initialize(
      max_attempts: nil,
      priority: nil,
      queue: nil,
      scheduled_at: nil,
      tags: nil,
      unique_opts: nil
    )
      self.max_attempts = max_attempts
      self.priority = priority
      self.queue = queue
      self.scheduled_at = scheduled_at
      self.tags = tags
      self.unique_opts = unique_opts
    end
  end

  class UniqueOpts
  end
end
