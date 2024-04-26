require "spec_helper"

# We use a mock here, but each driver has a more comprehensive test suite that
# performs full integration level tests.
class MockDriver
  def initialize
    @insert_params = []
    @next_id = 0
  end

  def insert(insert_params)
    @insert_params << insert_params

    River::JobRow.new(
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
    it "inserts many jobs" do
      expect do
        client.insert_many([])
      end.to raise_error(RuntimeError, "sorry, not implemented yet")
    end
  end
end

RSpec.describe River::InsertManyParams do
  it "initializes" do
    args = SimpleArgs.new(job_num: 1)
    insert_opts = River::InsertOpts.new(queue: "other")

    params = River::InsertManyParams.new(args, insert_opts: insert_opts)
    expect(params.args).to eq(args)
    expect(params.insert_opts).to eq(insert_opts)
  end
end
