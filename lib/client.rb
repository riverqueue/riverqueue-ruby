require "digest"
require "time"

module River
  # Default number of maximum attempts for a job.
  MAX_ATTEMPTS_DEFAULT = 25

  # Default priority for a job.
  PRIORITY_DEFAULT = 1

  # Default queue for a job.
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
      @time_now_utc = -> { Time.now.utc } # for test time stubbing
    end

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
      insert_params = make_insert_params(args, insert_opts)
      insert_and_check_unique_job(insert_params)
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

      @driver.job_insert_many(all_params)
        .map do |job, unique_skipped_as_duplicate|
        InsertResult.new(job, unique_skipped_as_duplicated: unique_skipped_as_duplicate)
      end
    end

    # Default states that are used during a unique insert. Can be overridden by
    # setting UniqueOpts#by_state.
    DEFAULT_UNIQUE_STATES = [
      JOB_STATE_AVAILABLE,
      JOB_STATE_COMPLETED,
      JOB_STATE_PENDING,
      JOB_STATE_RETRYABLE,
      JOB_STATE_RUNNING,
      JOB_STATE_SCHEDULED
    ].freeze
    private_constant :DEFAULT_UNIQUE_STATES

    REQUIRED_UNIQUE_STATES = [
      JOB_STATE_AVAILABLE,
      JOB_STATE_PENDING,
      JOB_STATE_RUNNING,
      JOB_STATE_SCHEDULED
    ].freeze
    private_constant :REQUIRED_UNIQUE_STATES

    EMPTY_INSERT_OPTS = InsertOpts.new.freeze
    private_constant :EMPTY_INSERT_OPTS

    private def insert_and_check_unique_job(insert_params)
      job, unique_skipped_as_duplicate = @driver.job_insert(insert_params)
      InsertResult.new(job, unique_skipped_as_duplicated: unique_skipped_as_duplicate)
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

      insert_params = Driver::JobInsertParams.new(
        encoded_args: args_json,
        kind: args.kind,
        max_attempts: insert_opts.max_attempts || args_insert_opts.max_attempts || MAX_ATTEMPTS_DEFAULT,
        priority: insert_opts.priority || args_insert_opts.priority || PRIORITY_DEFAULT,
        queue: insert_opts.queue || args_insert_opts.queue || QUEUE_DEFAULT,
        scheduled_at: scheduled_at&.utc || Time.now,
        state: scheduled_at ? JOB_STATE_SCHEDULED : JOB_STATE_AVAILABLE,
        tags: validate_tags(insert_opts.tags || args_insert_opts.tags || [])
      )

      unique_opts = insert_opts.unique_opts || args_insert_opts.unique_opts
      if unique_opts
        unique_key, unique_states = make_unique_key_and_bitmask(insert_params, unique_opts)
        insert_params.unique_key = unique_key
        insert_params.unique_states = unique_states
      end
      insert_params
    end

    private def make_unique_key_and_bitmask(insert_params, unique_opts)
      unique_key = ""

      # It's extremely important here that this unique key format and algorithm
      # match the one in the main River library _exactly_. Don't change them
      # unless they're updated everywhere.
      unless unique_opts.exclude_kind
        unique_key += "&kind=#{insert_params.kind}"
      end

      if unique_opts.by_args
        parsed_args = JSON.parse(insert_params.encoded_args)
        filtered_args = if unique_opts.by_args.is_a?(Array)
          parsed_args.select { |k, _| unique_opts.by_args.include?(k) }
        else
          parsed_args
        end

        encoded_args = JSON.generate(filtered_args.sort.to_h)
        unique_key += "&args=#{encoded_args}"
      end

      if unique_opts.by_period
        lower_period_bound = truncate_time(@time_now_utc.call, unique_opts.by_period).utc

        unique_key += "&period=#{lower_period_bound.strftime("%FT%TZ")}"
      end

      if unique_opts.by_queue
        unique_key += "&queue=#{insert_params.queue}"
      end

      unique_key_hash = Digest::SHA256.digest(unique_key)
      unique_states = validate_unique_states(unique_opts.by_state || DEFAULT_UNIQUE_STATES)

      [unique_key_hash, UniqueBitmask.from_states(unique_states)]
    end

    # Truncates the given time down to the interval. For example:
    #
    #   Thu Jan 15 21:26:36 UTC 2024 @ 15 minutes ->
    #   Thu Jan 15 21:15:00 UTC 2024
    private def truncate_time(time, interval_seconds)
      Time.at((time.to_f / interval_seconds).floor * interval_seconds)
    end

    # Moves an integer that may occupy the entire uint64 space to one that's
    # bounded within int64. Allows overflow.
    private def uint64_to_int64(int)
      [int].pack("Q").unpack1("q") #: Integer # rubocop:disable Layout/LeadingCommentSpace
    end

    TAG_RE = /\A[\w][\w\-]+[\w]\z/
    private_constant :TAG_RE

    private def validate_tags(tags)
      tags.each do |tag|
        raise ArgumentError, "tags should be 255 characters or less" if tag.length > 255
        raise ArgumentError, "tag should match regex #{TAG_RE.inspect}" unless TAG_RE.match(tag)
      end
    end

    private def validate_unique_states(states)
      REQUIRED_UNIQUE_STATES.each do |required_state|
        raise ArgumentError, "by_state should include required state #{required_state}" unless states.include?(required_state)
      end
      states
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
    # Inserted job row, or an existing job row if insert was skipped due to a
    # previously existing unique job.
    attr_reader :job

    # True if for a unique job, the insertion was skipped due to an equivalent
    # job matching unique property already being present.
    attr_reader :unique_skipped_as_duplicated

    def initialize(job, unique_skipped_as_duplicated:)
      @job = job
      @unique_skipped_as_duplicated = unique_skipped_as_duplicated
    end
  end
end
