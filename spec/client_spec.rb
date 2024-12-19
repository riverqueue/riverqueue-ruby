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

class ComplexArgs
  attr_accessor :customer_id
  attr_accessor :order_id
  attr_accessor :trace_id
  attr_accessor :email

  def initialize(customer_id:, order_id:, trace_id:, email:)
    self.customer_id = customer_id
    self.order_id = order_id
    self.trace_id = trace_id
    self.email = email
  end

  def kind = "complex"

  # intentionally not sorted alphabetically so we can ensure that the JSON
  # used in the unique key is sorted.
  def to_json = JSON.dump({order_id: order_id, customer_id: customer_id, trace_id: trace_id, email: email})
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

      it "inserts a new unique job with minimal options" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        unique_key_str = "&kind=#{insert_res.job.kind}" \
          "&queue=#{River::QUEUE_DEFAULT}"
        expect(insert_res.job.unique_key).to eq(Digest::SHA256.digest(unique_key_str))
        expect(insert_res.job.unique_states).to eq([River::JOB_STATE_AVAILABLE, River::JOB_STATE_COMPLETED, River::JOB_STATE_PENDING, River::JOB_STATE_RETRYABLE, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED])

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with custom states" do
        job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
        job_args.insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED]
          )
        )

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        lock_str = "&kind=#{job_args.kind}" \
          "&queue=#{River::QUEUE_DEFAULT}"

        expect(insert_res.job.unique_key).to eq(Digest::SHA256.digest(lock_str))
        expect(insert_res.job.unique_states).to eq([River::JOB_STATE_AVAILABLE, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED])

        insert_res = client.insert(job_args)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with all options" do
        job_args = ComplexArgs.new(customer_id: 1, order_id: 2, trace_id: 3, email: "john@example.com")
        insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(
            by_args: true,
            by_period: 15 * 60,
            by_queue: true,
            by_state: [River::JOB_STATE_AVAILABLE, River::JOB_STATE_CANCELLED, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED],
            exclude_kind: true
          )
        )

        insert_res = client.insert(job_args, insert_opts: insert_opts)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        sorted_json = {customer_id: 1, email: "john@example.com", order_id: 2, trace_id: 3}
        unique_key_str = "&args=#{JSON.dump(sorted_json)}" \
          "&period=#{client.send(:truncate_time, now, 15 * 60).utc.strftime("%FT%TZ")}" \
          "&queue=#{River::QUEUE_DEFAULT}"
        expect(insert_res.job.unique_key).to eq(Digest::SHA256.digest(unique_key_str))
        expect(insert_res.job.unique_states).to eq([River::JOB_STATE_AVAILABLE, River::JOB_STATE_CANCELLED, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED])

        insert_res = client.insert(job_args, insert_opts: insert_opts)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be true
      end

      it "inserts a new unique job with custom by_args" do
        job_args = ComplexArgs.new(customer_id: 1, order_id: 2, trace_id: 3, email: "john@example.com")
        insert_opts = River::InsertOpts.new(
          unique_opts: River::UniqueOpts.new(by_args: ["customer_id", "order_id"])
        )

        insert_res = client.insert(job_args, insert_opts: insert_opts)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false
        original_job_id = insert_res.job.id

        unique_key_str = "&kind=complex&args=#{JSON.dump({customer_id: 1, order_id: 2})}"
        expect(insert_res.job.unique_key).to eq(Digest::SHA256.digest(unique_key_str))

        insert_res = client.insert(job_args, insert_opts: insert_opts)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.job.id).to eq(original_job_id)
        expect(insert_res.unique_skipped_as_duplicated).to be true

        # Change just the customer ID and the job should be unique again.
        job_args.customer_id = 2
        insert_res = client.insert(job_args, insert_opts: insert_opts)
        expect(insert_res.job).to_not be_nil
        expect(insert_res.job.id).to_not eq(original_job_id)
        expect(insert_res.unique_skipped_as_duplicated).to be false
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

      it "errors if any of the required unique states are removed from a custom by_states list" do
        default_states = [River::JOB_STATE_AVAILABLE, River::JOB_STATE_COMPLETED, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_RETRYABLE, River::JOB_STATE_SCHEDULED]
        required_states = [River::JOB_STATE_AVAILABLE, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED]
        required_states.each do |state|
          job_args = SimpleArgsWithInsertOpts.new(job_num: 1)
          job_args.insert_opts = River::InsertOpts.new(
            unique_opts: River::UniqueOpts.new(
              by_state: default_states - [state]
            )
          )

          expect do
            client.insert(job_args)
          end.to raise_error(ArgumentError, "by_state should include required state #{state}")
        end
      end
    end
  end

  describe "#insert_many" do
    it "inserts jobs from jobArgs with defaults" do
      results = client.insert_many([
        SimpleArgs.new(job_num: 1),
        SimpleArgs.new(job_num: 2)
      ])
      expect(results.length).to eq(2)
      expect(results[0].job).to have_attributes(args: {"job_num" => 1})
      expect(results[1].job).to have_attributes(args: {"job_num" => 2})

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
      results = client.insert_many([
        River::InsertManyParams.new(SimpleArgs.new(job_num: 1)),
        River::InsertManyParams.new(SimpleArgs.new(job_num: 2))
      ])
      expect(results.length).to eq(2)
      expect(results[0].job).to have_attributes(args: {"job_num" => 1})
      expect(results[1].job).to have_attributes(args: {"job_num" => 2})

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
      # First, insert a job which will cause a duplicate conflict with the bulk
      # insert so the bulk insert's row gets skipped.
      dupe_job_args = SimpleArgsWithInsertOpts.new(job_num: 0)
      dupe_job_args.insert_opts = River::InsertOpts.new(
        queue: "job_to_duplicate",
        unique_opts: River::UniqueOpts.new(
          by_queue: true
        )
      )

      insert_res = client.insert(dupe_job_args)
      expect(insert_res.job).to_not be_nil

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
      args3 = SimpleArgsWithInsertOpts.new(job_num: 3)
      args3.insert_opts = River::InsertOpts.new(
        queue: "to_duplicate", # duplicate by queue, will be skipped
        tags: ["job_custom_3"],
        unique_opts: River::UniqueOpts.new(
          by_queue: true
        )
      )

      results = client.insert_many([
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
        )),
        River::InsertManyParams.new(args3, insert_opts: River::InsertOpts.new(
          queue: "job_to_duplicate", # duplicate by queue, will be skipped
          tags: ["custom_3"],
          unique_opts: River::UniqueOpts.new(
            by_queue: true
          )
        ))
      ])
      expect(results.length).to eq(3) # all rows returned, including skipped duplicates
      expect(results[0].job).to have_attributes(tags: ["custom_1"])
      expect(results[1].job).to have_attributes(tags: ["custom_2"])
      expect(results[2].unique_skipped_as_duplicated).to be true
      expect(results[2].job).to have_attributes(
        id: insert_res.job.id,
        tags: []
      )

      jobs = driver.job_list
      expect(jobs.count).to be 3

      expect(jobs[0]).to have_attributes(queue: "job_to_duplicate")

      expect(jobs[1]).to have_attributes(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue_1",
        tags: ["custom_1"]
      )

      expect(jobs[2]).to have_attributes(
        max_attempts: 18,
        priority: 4,
        queue: "my_queue_2",
        tags: ["custom_2"]
      )
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
