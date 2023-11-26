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
      attempt: 0,
      attempted_by: nil,
      created_at: Time.now,
      encoded_args: insert_params.encoded_args,
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
      job = client.insert(SimpleArgs.new(job_num: 1))
      expect(job).to have_attributes(
        id: 1,
        attempt: 0,
        created_at: be_within(2).of(Time.now),
        encoded_args: %({"job_num":1}),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: be_within(2).of(Time.now),
        state: River::JOB_STATE_AVAILABLE,
        tags: nil
      )
    end

    it "schedules a job" do
      target_time = Time.now + 1 * 3600

      job = client.insert(
        SimpleArgs.new(job_num: 1),
        insert_opts: River::InsertOpts.new(scheduled_at: target_time)
      )
      expect(job).to have_attributes(
        scheduled_at: be_within(2).of(target_time),
        state: River::JOB_STATE_SCHEDULED
      )
    end

    it "inserts with job insert opts" do
      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        max_attempts: 23,
        priority: 2,
        queue: "job_custom_queue",
        tags: ["job_custom"]
      )

      job = client.insert(args)
      expect(job).to have_attributes(
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

      job = client.insert(args, insert_opts: River::InsertOpts.new(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue",
        tags: ["custom"]
      ))
      expect(job).to have_attributes(
        max_attempts: 17,
        priority: 3,
        queue: "my_queue",
        tags: ["custom"]
      )
    end

    it "inserts with job args hash" do
      job = client.insert(River::JobArgsHash.new("hash_kind", {
        job_num: 1
      }))
      expect(job).to have_attributes(
        encoded_args: %({"job_num":1}),
        kind: "hash_kind"
      )
    end
  end
end
