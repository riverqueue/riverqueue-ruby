require "spec_helper"
require_relative "../driver/riverqueue-sequel/spec/spec_helper"

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

# I originally had this top-level client test set up so that it was using a mock
# driver, but it just turned out to be too horribly unsustainable. Adding
# anything new required careful mock engineering, and even once done, we weren't
# getting good guarantees that the right things were happening because it wasn't
# end to end. We now use the real Sequel driver, with the only question being
# whether we should maybe move all these tests into the common driver shared
# examples so that all drivers get the full barrage.
RSpec.describe River::Client do
  around(:each) { |ex| test_transaction(&ex) }

  let!(:driver) { River::Driver::Sequel.new(DB) }
  let(:client) { River::Client.new(driver) }

  describe "#insert" do
    it "inserts a job with defaults" do
      insert_res = client.insert(SimpleArgs.new(job_num: 1))
      expect(insert_res.job).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
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
      job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
      job_args.insert_opts = River::InsertOpts.new(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue",
        tags: ["job_custom"]
      )

      insert_res = client.insert(job_args)
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
      job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
      job_args.insert_opts = River::InsertOpts.new(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue",
        tags: ["job_custom"]
      )

      insert_res = client.insert(job_args, insert_opts: River::InsertOpts.new(
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

    it "errors if advisory lock prefix is larger than four bytes" do
      River::Client.new(driver, advisory_lock_prefix: 123)

      expect do
        River::Client.new(driver, advisory_lock_prefix: -1)
      end.to raise_error(ArgumentError, "advisory lock prefix must fit inside four bytes")

      # 2^32-1 is 0xffffffff (1s for 32 bits) which fits
      River::Client.new(driver, advisory_lock_prefix: 2**32 - 1)

      # 2^32 is 0x100000000, which does not
      expect do
        River::Client.new(driver, advisory_lock_prefix: 2**32)
      end.to raise_error(ArgumentError, "advisory lock prefix must fit inside four bytes")
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

    it "raises error if tags are too long" do
      expect do
        client.insert(SimpleArgs.new(job_num: 1), insert_opts: River::InsertOpts.new(
          tags: ["a" * 256]
        ))
      end.to raise_error(ArgumentError, "tags should be 255 characters or less")
    end

    it "raises error if tags are misformatted" do
      expect do
        client.insert(SimpleArgs.new(job_num: 1), insert_opts: River::InsertOpts.new(
          tags: ["no,commas,allowed"]
        ))
      end.to raise_error(ArgumentError, 'tag should match regex /\A[\w][\w\-]+[\w]\z/')
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

      let(:advisory_lock_keys) { [] }

      before do
        # required so it's properly captured by the lambda below
        keys = advisory_lock_keys

        driver.singleton_class.send(:define_method, :advisory_lock, ->(key) { keys.push(key) })
      end

      it "inserts a new unique job with minimal options on the fast path" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        expect(advisory_lock_keys).to be_empty

        unique_key_str = "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{River::Client.const_get(:DEFAULT_UNIQUE_STATES).join(",")}"
        expect(insert_res.job.unique_key).to eq(Digest::SHA256.digest(unique_key_str))

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with minimal options on the slow path" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE, River::JOB_STATE_RUNNING] # non-default triggers slow path
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "unique_keykind=#{job_args.kind}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{job_args.insert_opts.unique_opts.by_state.join(",")}"
        expect(advisory_lock_keys).to eq([check_bigint_bounds(client.send(:uint64_to_int64, River::FNV.fnv1_hash(lock_str, size: 64)))])

        expect(insert_res.job.unique_key).to be_nil

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with all options on the fast path" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_args: true,
            by_period: 15 * 60,
            by_queue: true,
            by_state: River::Client.const_get(:DEFAULT_UNIQUE_STATES)
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        expect(advisory_lock_keys).to be_empty

        unique_key_str = "&args=#{JSON.dump({job_num: 1})}" \
          "&period=#{client.send(:truncate_time, now, 15 * 60).utc.strftime("%FT%TZ")}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{River::Client.const_get(:DEFAULT_UNIQUE_STATES).join(",")}"
        expect(insert_res.job.unique_key).to eq(Digest::SHA256.digest(unique_key_str))

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with all options on the slow path" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_args: true,
            by_period: 15 * 60,
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE]
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "unique_keykind=#{job_args.kind}" \
          "&args=#{JSON.dump({job_num: 1})}" \
          "&period=#{client.send(:truncate_time, now, 15 * 60).utc.strftime("%FT%TZ")}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{[River::JOB_STATE_AVAILABLE].join(",")}"
        expect(advisory_lock_keys).to eq([check_bigint_bounds(client.send(:uint64_to_int64, River::FNV.fnv1_hash(lock_str, size: 64)))])

        expect(insert_res.job.unique_key).to be_nil

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with advisory lock prefix" do
        client = River::Client.new(driver, advisory_lock_prefix: 123456)

        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE, River::JOB_STATE_RUNNING] # non-default triggers slow path
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "unique_keykind=#{job_args.kind}" \
          "&queue=#{River::QUEUE_DEFAULT}" \
          "&state=#{job_args.insert_opts.unique_opts.by_state.join(",")}"
        expect(advisory_lock_keys).to eq([check_bigint_bounds(client.send(:uint64_to_int64, 123456 << 32 | River::FNV.fnv1_hash(lock_str, size: 32)))])

        lock_key = advisory_lock_keys[0]
        expect(lock_key >> 32).to eq(123456)
      end

      it "skips unique check if unique opts empty" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new
        )

        insert_res = client.insert(job_args)
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

      jobs = driver.job_list
      expect(jobs.count).to be 2

      expect(jobs[0]).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )

      expect(jobs[1]).to have_attributes(
        args: {"job_num" => 2},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )
    end

    it "inserts jobs from InsertManyParams with defaults" do
      num_inserted = client.insert_many([
        River::InsertManyParams.new(SimpleArgs.new(job_num: 1)),
        River::InsertManyParams.new(SimpleArgs.new(job_num: 2))
      ])
      expect(num_inserted).to eq(2)

      jobs = driver.job_list
      expect(jobs.count).to be 2

      expect(jobs[0]).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )

      expect(jobs[1]).to have_attributes(
        args: {"job_num" => 2},
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
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

      jobs = driver.job_list
      expect(jobs.count).to be 2

      expect(jobs[0]).to have_attributes(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue_1",
        tags: ["custom_1"]
      )

      expect(jobs[1]).to have_attributes(
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

  describe River::Client.const_get(:DEFAULT_UNIQUE_STATES) do
    it "should be sorted" do
      expect(River::Client.const_get(:DEFAULT_UNIQUE_STATES)).to eq(River::Client.const_get(:DEFAULT_UNIQUE_STATES).sort)
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
    job_args = SimpleArgs.new(job_num: 1)

    params = River::InsertManyParams.new(job_args)
    expect(params.args).to eq(job_args)
    expect(params.insert_opts).to be_nil
  end

  it "initializes with insert opts" do
    job_args = SimpleArgs.new(job_num: 1)
    insert_opts = River::InsertOpts.new(queue: "other")

    params = River::InsertManyParams.new(job_args, insert_opts: insert_opts)
    expect(params.args).to eq(job_args)
    expect(params.insert_opts).to eq(insert_opts)
  end
end
