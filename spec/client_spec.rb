require "spec_helper"

# We use a mock here, but each driver has a more comprehensive test suite that
# performs full integration level tests.
class MockDriver
  attr_accessor :inserted_jobs

  def initialize
    @inserted_jobs = []
    @next_id = 0
  end

  def insert(insert_params)
    insert_params_to_jow_row(insert_params)
  end

  def insert_many(insert_params_many)
    insert_params_many.each do |insert_params|
      insert_params_to_jow_row(insert_params)
    end
    insert_params_many.count
  end

  private def insert_params_to_jow_row(insert_params)
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
