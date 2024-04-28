require "spec_helper"

# We use a mock here, but each driver has a more comprehensive test suite that
# performs full integration level tests.
class MockDriver
  attr_accessor :advisory_lock_calls
  attr_accessor :inserted_jobs
  attr_accessor :job_get_by_kind_and_unique_properties_calls
  attr_accessor :job_get_by_kind_and_unique_properties_returns

  def initialize
    @advisory_lock_calls = []
    @inserted_jobs = []
    @job_get_by_kind_and_unique_properties_calls = []
    @job_get_by_kind_and_unique_properties_returns = []
    @next_id = 0
  end

  def advisory_lock(key)
    @advisory_lock_calls << key
  end

  def job_get_by_kind_and_unique_properties(get_params)
    @job_get_by_kind_and_unique_properties_calls << get_params
    job_get_by_kind_and_unique_properties_returns.shift
  end

  def job_insert(insert_params)
    insert_params_to_jow_row(insert_params)
  end

  def job_insert_many(insert_params_many)
    insert_params_many.each do |insert_params|
      insert_params_to_jow_row(insert_params)
    end
    insert_params_many.count
  end

  def transaction(&)
    yield
  end

  def insert_params_to_jow_row(insert_params)
    job = River::JobRow.new(
      id: (@next_id += 1),
      args: JSON.parse(insert_params.encoded_args),
      attempt: 0,
      attempted_by: nil,
      created_at: Time.now,
      errors: nil,
      finalized_at: nil,
      kind: insert_params.kind,
      max_attempts: insert_params.max_attempts,
      priority: insert_params.priority,
      queue: insert_params.queue,
      scheduled_at: insert_params.scheduled_at || Time.now, # normally defaults from DB
      state: insert_params.state,
      tags: insert_params.tags
    )
    inserted_jobs << job
    job
  end
end

class SimpleArgs
  attr_accessor :job_num

  def initialize(job_num:)
    self.job_num = job_num
  end

  def kind = "simple"

  def to_json = JSON.dump({job_num: job_num})
end

# Lets us test job-specific insertion opts by making `#insert_opts` an accessor.
# Real args that make use of this functionality will probably want to make
# `#insert_opts` a non-accessor method instead.
class SimpleArgsWithInsertOpts < SimpleArgs
  attr_accessor :insert_opts
end

RSpec.describe River::Client do
  let(:client) { River::Client.new(mock_driver) }
  let(:mock_driver) { MockDriver.new }

  describe "#insert" do
    it "inserts a job with defaults" do
      insert_res = client.insert(SimpleArgs.new(job_num: 1))
      expect(insert_res.job).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: nil
      )
    end

    it "schedules a job" do
      target_time = Time.now + 1 * 3600

      insert_res = client.insert(
        SimpleArgs.new(job_num: 1),
        insert_opts: River::InsertOpts.new(scheduled_at: target_time)
      )
      expect(insert_res.job).to have_attributes(
        scheduled_at: be_within(2).of(target_time),
        state: River::JOB_STATE_SCHEDULED
      )

      # Expect all inserted timestamps to go to UTC.
      expect(insert_res.job.scheduled_at.utc?).to be true
    end

    it "inserts with job insert opts" do
      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue",
        tags: ["job_custom"]
      )

      insert_res = client.insert(args)
      expect(insert_res.job).to have_attributes(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue",
        tags: ["job_custom"]
      )
    end

    it "inserts with insert opts" do
      # We set job insert opts in this spec too so that we can verify that the
      # options passed at insertion time take precedence.
      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue",
        tags: ["job_custom"]
      )

      insert_res = client.insert(args, insert_opts: River::InsertOpts.new(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue",
        tags: ["custom"]
      ))
      expect(insert_res.job).to have_attributes(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue",
        tags: ["custom"]
      )
    end

    it "inserts with job args hash" do
      insert_res = client.insert(River::JobArgsHash.new("hash_kind", {
        job_num: 1
      }))
      expect(insert_res.job).to have_attributes(
        args: {"job_num" => 1},
        kind: "hash_kind"
      )
    end

    it "errors if args don't respond to #kind" do
      args_klass = Class.new do
        def to_json = {}
      end

      expect do
        client.insert(args_klass.new)
      end.to raise_error(RuntimeError, "args should respond to `#kind`")
    end

    it "errors if args return nil from #to_json" do
      args_klass = Class.new do
        def kind = "args_kind"

        def to_json = nil
      end

      expect do
        client.insert(args_klass.new)
      end.to raise_error(RuntimeError, "args should return non-nil from `#to_json`")
    end

    def check_bigint_bounds(int)
      raise "lock key shouldn't be larger than Postgres bigint max (9223372036854775807); was: #{int}" if int > 9223372036854775807
      raise "lock key shouldn't be smaller than Postgres bigint min (-9223372036854775808); was: #{int}" if int < -9223372036854775808
      int
    end

    # These unique insertion specs are pretty mock heavy, but each of the
    # individual drivers has their own unique insert tests that make sure to do
    # a full round trip.
    describe "unique opts" do
      let(:now) { Time.now.utc }
      before { client.instance_variable_set(:@time_now_utc, -> { now }) }

      it "inserts a new unique job with minimal options" do
        args = SimpleArgsWithInsertOpts.new(job_num: 1)
        args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true
          )
        )

        insert_res = client.insert(args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "unique_keykind=#{args.kind}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{River::Client.const_get(:DEFAULT_UNIQUE_STATES).join(",")}"
        expect(mock_driver.advisory_lock_calls).to eq([check_bigint_bounds(client.send(:uint64_to_int64, Fnv::Hash.fnv_1(lock_str, size: 64)))])
      end

      it "inserts a new unique job with all options" do
        args = SimpleArgsWithInsertOpts.new(job_num: 1)
        args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_args: true,
            by_period: 15 * 60,
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE]
          )
        )

        insert_res = client.insert(args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "unique_keykind=#{args.kind}" \
          "&args=#{JSON.dump({job_num: 1})}" \
          "&period=#{client.send(:truncate_time, now, 15 * 60).utc.strftime("%FT%TZ")}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{[River::JOB_STATE_AVAILABLE].join(",")}"
        expect(mock_driver.advisory_lock_calls).to eq([check_bigint_bounds(client.send(:uint64_to_int64, Fnv::Hash.fnv_1(lock_str, size: 64)))])
      end

      it "inserts a new unique job with advisory lock prefix" do
        client = River::Client.new(mock_driver, advisory_lock_prefix: 123456)

        args = SimpleArgsWithInsertOpts.new(job_num: 1)
        args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true
          )
        )

        insert_res = client.insert(args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "unique_keykind=#{args.kind}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{River::Client.const_get(:DEFAULT_UNIQUE_STATES).join(",")}"
        expect(mock_driver.advisory_lock_calls).to eq([check_bigint_bounds(client.send(:uint64_to_int64, 123456 << 32 | Fnv::Hash.fnv_1(lock_str, size: 32)))])

        lock_key = mock_driver.advisory_lock_calls[0]
        expect(lock_key >> 32).to eq(123456)
      end

      it "gets an existing unique job" do
        args = SimpleArgsWithInsertOpts.new(job_num: 1)
        args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_args: true,
            by_period: 15 * 60,
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE]
          )
        )

        job = mock_driver.insert_params_to_jow_row(client.send(:make_insert_params, args, River::InsertOpts.new)[0])
        mock_driver.job_get_by_kind_and_unique_properties_returns << job

        insert_res = client.insert(args)
        expect(insert_res).to have_attributes(
          job: job,
          unique_skipped_as_duplicated: true
        )

        lock_str = "unique_keykind=#{args.kind}" \
          "&args=#{JSON.dump({job_num: 1})}" \
          "&period=#{client.send(:truncate_time, now, 15 * 60).utc.strftime("%FT%TZ")}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{[River::JOB_STATE_AVAILABLE].join(",")}"
        expect(mock_driver.advisory_lock_calls).to eq([check_bigint_bounds(client.send(:uint64_to_int64, Fnv::Hash.fnv_1(lock_str, size: 64)))])
      end

      it "skips unique check if unique opts empty" do
        args = SimpleArgsWithInsertOpts.new(job_num: 1)
        args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new
        )

        insert_res = client.insert(args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false
      end
    end
  end

  describe "#insert_many" do
    it "inserts jobs from jobArgs with defaults" do
      num_inserted = client.insert_many([
        SimpleArgs.new(job_num: 1),
        SimpleArgs.new(job_num: 2)
      ])
      expect(num_inserted).to eq(2)

      job1 = mock_driver.inserted_jobs[0]
      expect(job1).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: nil
      )

      job2 = mock_driver.inserted_jobs[1]
      expect(job2).to have_attributes(
        id: 2,
        args: {"job_num" => 2},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: nil
      )
    end

    it "inserts jobs from InsertManyParams with defaults" do
      num_inserted = client.insert_many([
        River::InsertManyParams.new(SimpleArgs.new(job_num: 1)),
        River::InsertManyParams.new(SimpleArgs.new(job_num: 2))
      ])
      expect(num_inserted).to eq(2)

      job1 = mock_driver.inserted_jobs[0]
      expect(job1).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: nil
      )

      job2 = mock_driver.inserted_jobs[1]
      expect(job2).to have_attributes(
        id: 2,
        args: {"job_num" => 2},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: nil
      )
    end

    it "inserts jobs with insert opts" do
      # We set job insert opts in this spec too so that we can verify that the
      # options passed at insertion time take precedence.
      args1 = SimpleArgsWithInsertOpts.new(job_num: 1)
      args1.insert_opts = River::InsertOpts.new(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue_1",
        tags: ["job_custom_1"]
      )
      args2 = SimpleArgsWithInsertOpts.new(job_num: 2)
      args2.insert_opts = River::InsertOpts.new(
        max_attempts: 24,
        priority: 3,
        queue: "job_custom_queue_2",
        tags: ["job_custom_2"]
      )

      num_inserted = client.insert_many([
        River::InsertManyParams.new(args1, insert_opts: River::InsertOpts.new(
          max_attempts: 17,
          priority: 3,
          queue: "my_queue_1",
          tags: ["custom_1"]
        )),
        River::InsertManyParams.new(args2, insert_opts: River::InsertOpts.new(
          max_attempts: 18,
          priority: 4,
          queue: "my_queue_2",
          tags: ["custom_2"]
        ))
      ])
      expect(num_inserted).to eq(2)

      job1 = mock_driver.inserted_jobs[0]
      expect(job1).to have_attributes(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue_1",
        tags: ["custom_1"]
      )

      job2 = mock_driver.inserted_jobs[1]
      expect(job2).to have_attributes(
        max_attempts: 18,
        priority: 4,
        queue: "my_queue_2",
        tags: ["custom_2"]
      )
    end

    it "raises error with unique opts" do
      expect do
        client.insert_many([
          River::InsertManyParams.new(SimpleArgs.new(job_num: 1), insert_opts: River::InsertOpts.new(
            unique_opts: River::UniqueOpts.new
          ))
        ])
      end.to raise_error(ArgumentError, "unique opts can't be used with `#insert_many`")
    end
  end

  describe "#truncate_time" do
    it "truncates times to nearest interval" do
      expect(client.send(:truncate_time, Time.parse("Thu Jan 15 21:26:36 UTC 2024").utc,       1 * 60).utc).to eq(Time.parse("Thu Jan 15 21:26:00 UTC 2024")) # rubocop:disable Layout/ExtraSpacing
      expect(client.send(:truncate_time, Time.parse("Thu Jan 15 21:26:36 UTC 2024").utc,       5 * 60).utc).to eq(Time.parse("Thu Jan 15 21:25:00 UTC 2024")) # rubocop:disable Layout/ExtraSpacing
      expect(client.send(:truncate_time, Time.parse("Thu Jan 15 21:26:36 UTC 2024").utc,      15 * 60).utc).to eq(Time.parse("Thu Jan 15 21:15:00 UTC 2024")) # rubocop:disable Layout/ExtraSpacing
      expect(client.send(:truncate_time, Time.parse("Thu Jan 15 21:26:36 UTC 2024").utc,  1 * 60 * 60).utc).to eq(Time.parse("Thu Jan 15 21:00:00 UTC 2024")) # rubocop:disable Layout/ExtraSpacing
      expect(client.send(:truncate_time, Time.parse("Thu Jan 15 21:26:36 UTC 2024").utc,  5 * 60 * 60).utc).to eq(Time.parse("Thu Jan 15 17:00:00 UTC 2024")) # rubocop:disable Layout/ExtraSpacing
      expect(client.send(:truncate_time, Time.parse("Thu Jan 15 21:26:36 UTC 2024").utc, 24 * 60 * 60).utc).to eq(Time.parse("Thu Jan 15 00:00:00 UTC 2024"))
    end
  end

  describe "#uint64_to_int64" do
    it "converts between integer types" do
      expect(client.send(:uint64_to_int64, 123456)).to eq(123456)
      expect(client.send(:uint64_to_int64, 13977996710702069744)).to eq(-4468747363007481872)
    end
  end
end

RSpec.describe River::InsertManyParams do
  it "initializes" do
    args = SimpleArgs.new(job_num: 1)

    params = River::InsertManyParams.new(args)
    expect(params.args).to eq(args)
    expect(params.insert_opts).to be_nil
  end

  it "initializes with insert opts" do
    args = SimpleArgs.new(job_num: 1)
    insert_opts = River::InsertOpts.new(queue: "other")

    params = River::InsertManyParams.new(args, insert_opts: insert_opts)
    expect(params.args).to eq(args)
    expect(params.insert_opts).to eq(insert_opts)
  end
end
