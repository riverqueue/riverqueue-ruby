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

    # Inserts a new job for work given a job args implementation and insertion
    # options (which may be omitted).
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
    def insert(args, insert_opts: InsertOpts.new)
      raise "args should respond to `#kind`" if !args.respond_to?(:kind)
      raise "args should respond to `#to_json`" if !args.respond_to?(:to_json)

      args_insert_opts = args.respond_to?(:insert_opts) ? args.insert_opts : InsertOpts.new

      scheduled_at = insert_opts.scheduled_at || args_insert_opts.scheduled_at

      @driver.insert(Internal::JobInsertParams.new(
        encoded_args: args.to_json,
        kind: args.kind,
        max_attempts: insert_opts.max_attempts || args_insert_opts.max_attempts || MAX_ATTEMPTS_DEFAULT,
        priority: insert_opts.priority || args_insert_opts.priority || PRIORITY_DEFAULT,
        queue: insert_opts.queue || args_insert_opts.queue || QUEUE_DEFAULT,
        scheduled_at: scheduled_at, # database default to now
        state: scheduled_at ? JOB_STATE_SCHEDULED : JOB_STATE_AVAILABLE,
        tags: insert_opts.tags || args_insert_opts.tags
      ))
    end
  end
end
