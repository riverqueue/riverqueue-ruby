module River
  MAX_ATTEMPTS_DEFAULT = 25
  PRIORITY_DEFAULT = 1
  QUEUE_DEFAULT = "default"

  # Provides a client for River that inserts jobs. Unlike the Go version of the
  # River client, this one can insert jobs only. Jobs can only be worked from Go
  # code, so job arg kinds and JSON encoding details must be shared between Ruby
  # and Go code.
  #
  # Used in conjunction with a River driver like:
  #
  #   DB = Sequel.connect(...)
  #   client = River::Client.new(River::Driver::Sequel.new(DB))
  #
  # River drivers are found in separate gems like `riverqueue-sequel` to help
  # minimize transient dependencies.
  class Client
    def initialize(driver)
      @driver = driver
    end

    EMPTY_INSERT_OPTS = InsertOpts.new.freeze
    private_constant :EMPTY_INSERT_OPTS

    # Inserts a new job for work given a job args implementation and insertion
    # options (which may be omitted).
    #
    # With job args only:
    #
    #   insert_res = client.insert(SimpleArgs.new(job_num: 1))
    #   insert_res.job # inserted job row
    #
    # With insert opts:
    #
    #   insert_res = client.insert(SimpleArgs.new(job_num: 1), insert_opts: InsertOpts.new(queue: "high_priority"))
    #   insert_res.job # inserted job row
    #
    # Job arg implementations are expected to respond to:
    #
    #   * `#kind`: A string that uniquely identifies the job in the database.
    #   * `#to_json`: Encodes the args to JSON for persistence in the database.
    #     Must match encoding an args struct on the Go side to be workable.
    #
    # They may also respond to `#insert_opts` which is expected to return an
    # `InsertOpts` that contains options that will apply to all jobs of this
    # kind. Insertion options provided as an argument to `#insert` override
    # those returned by job args.
    #
    # For example:
    #
    #   class SimpleArgs
    #     attr_accessor :job_num
    #
    #     def initialize(job_num:)
    #       self.job_num = job_num
    #     end
    #
    #     def kind = "simple"
    #
    #     def to_json = JSON.dump({job_num: job_num})
    #   end
    #
    # See also JobArgsHash for an easy way to insert a job from a hash.
    #
    # Returns an instance of InsertResult.
    def insert(args, insert_opts: EMPTY_INSERT_OPTS)
      job = @driver.insert(make_insert_params(args, insert_opts))
      InsertResult.new(job)
    end

    # Inserts many new jobs as part of a single batch operation for improved
    # efficiency.
    #
    # Takes an array of job args or InsertManyParams which encapsulate job args
    # and a paired InsertOpts.
    #
    # With job args:
    #
    #   num_inserted = client.insert_many([
    #     SimpleArgs.new(job_num: 1),
    #     SimpleArgs.new(job_num: 2)
    #   ])
    #
    # With InsertManyParams:
    #
    #   num_inserted = client.insert_many([
    #     River::InsertManyParams.new(SimpleArgs.new(job_num: 1), insert_opts: InsertOpts.new(max_attempts: 5)),
    #     River::InsertManyParams.new(SimpleArgs.new(job_num: 2), insert_opts: InsertOpts.new(queue: "high_priority"))
    #   ])
    #
    # Job arg implementations are expected to respond to:
    #
    #   * `#kind`: A string that uniquely identifies the job in the database.
    #   * `#to_json`: Encodes the args to JSON for persistence in the database.
    #     Must match encoding an args struct on the Go side to be workable.
    #
    # For example:
    #
    #   class SimpleArgs
    #     attr_accessor :job_num
    #
    #     def initialize(job_num:)
    #       self.job_num = job_num
    #     end
    #
    #     def kind = "simple"
    #
    #     def to_json = JSON.dump({job_num: job_num})
    #   end
    #
    # See also JobArgsHash for an easy way to insert a job from a hash.
    #
    # Returns the number of jobs inserted.
    def insert_many(args)
      all_params = args.map do |arg|
        if arg.is_a?(InsertManyParams)
          make_insert_params(arg.args, arg.insert_opts || EMPTY_INSERT_OPTS)
        else # jobArgs
          make_insert_params(arg, EMPTY_INSERT_OPTS)
        end
      end

      @driver.insert_many(all_params)
    end

    private def make_insert_params(args, insert_opts)
      raise "args should respond to `#kind`" if !args.respond_to?(:kind)

      # ~all objects in Ruby respond to `#to_json`, so check non-nil instead.
      args_json = args.to_json
      raise "args should return non-nil from `#to_json`" if !args_json

      args_insert_opts = if args.respond_to?(:insert_opts)
        args_with_insert_opts = args #: _JobArgsWithInsertOpts # rubocop:disable Layout/LeadingCommentSpace
        args_with_insert_opts.insert_opts || EMPTY_INSERT_OPTS
      else
        EMPTY_INSERT_OPTS
      end

      scheduled_at = insert_opts.scheduled_at || args_insert_opts.scheduled_at

      Driver::JobInsertParams.new(
        encoded_args: args_json,
        kind: args.kind,
        max_attempts: insert_opts.max_attempts || args_insert_opts.max_attempts || MAX_ATTEMPTS_DEFAULT,
        priority: insert_opts.priority || args_insert_opts.priority || PRIORITY_DEFAULT,
        queue: insert_opts.queue || args_insert_opts.queue || QUEUE_DEFAULT,
        scheduled_at: scheduled_at&.utc, # database defaults to now
        state: scheduled_at ? JOB_STATE_SCHEDULED : JOB_STATE_AVAILABLE,
        tags: insert_opts.tags || args_insert_opts.tags
      )
    end
  end

  # A single job to insert that's part of an #insert_many batch insert. Unlike
  # sending raw job args, supports an InsertOpts to pair with the job.
  class InsertManyParams
    # Job args to insert.
    attr_reader :args

    # Insertion options to use with the insert.
    attr_reader :insert_opts

    def initialize(args, insert_opts: nil)
      @args = args
      @insert_opts = insert_opts
    end
  end

  # Result of a single insertion.
  class InsertResult
    # Inserted job row.
    attr_reader :job

    def initialize(job)
      @job = job
    end
  end
end
