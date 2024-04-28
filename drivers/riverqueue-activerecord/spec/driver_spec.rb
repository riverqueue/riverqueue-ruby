require "spec_helper"

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

RSpec.describe River::Driver::ActiveRecord do
  around(:each) { |ex| test_transaction(&ex) }

  let!(:driver) { River::Driver::ActiveRecord.new }
  let(:client) { River::Client.new(driver) }

  describe "unique insertion" do
    it "inserts a unique job once" do
      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        unique_opts: River::UniqueOpts.new(
          by_queue: true
        )
      )

      insert_res = client.insert(args)
      expect(insert_res.job).to_not be_nil
      expect(insert_res.unique_skipped_as_duplicated).to be false
      original_job = insert_res.job

      insert_res = client.insert(args)
      expect(insert_res.job.id).to eq(original_job.id)
      expect(insert_res.unique_skipped_as_duplicated).to be true
    end

    it "inserts a unique job with an advisory lock prefix" do
      client = River::Client.new(driver, advisory_lock_prefix: 123456)

      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        unique_opts: River::UniqueOpts.new(
          by_queue: true
        )
      )

      insert_res = client.insert(args)
      expect(insert_res.job).to_not be_nil
      expect(insert_res.unique_skipped_as_duplicated).to be false
      original_job = insert_res.job

      insert_res = client.insert(args)
      expect(insert_res.job.id).to eq(original_job.id)
      expect(insert_res.unique_skipped_as_duplicated).to be true
    end
  end

  describe "#advisory_lock" do
    it "takes an advisory lock" do
      driver.advisory_lock(123)
    end
  end

  describe "#job_get_by_kind_and_unique_properties" do
    let(:job_args) { SimpleArgs.new(job_num: 1) }

    it "gets a job by kind" do
      insert_res = client.insert(job_args)

      job = driver.send(
        :to_job_row,
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind
        ))
      )
      expect(job.id).to eq(insert_res.job.id)

      expect(
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: "does_not_exist"
        ))
      ).to be_nil
    end

    it "gets a job by created at period" do
      insert_res = client.insert(job_args)

      job = driver.send(
        :to_job_row,
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          created_at: [insert_res.job.created_at - 1, insert_res.job.created_at + 1]
        ))
      )
      expect(job.id).to eq(insert_res.job.id)

      expect(
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          created_at: [insert_res.job.created_at + 1, insert_res.job.created_at + 3]
        ))
      ).to be_nil
    end

    it "gets a job by encoded args" do
      insert_res = client.insert(job_args)

      job = driver.send(
        :to_job_row,
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          encoded_args: JSON.dump(insert_res.job.args)
        ))
      )
      expect(job.id).to eq(insert_res.job.id)

      expect(
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          encoded_args: JSON.dump({"job_num" => 2})
        ))
      ).to be_nil
    end

    it "gets a job by queue" do
      insert_res = client.insert(job_args)

      job = driver.send(
        :to_job_row,
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          queue: insert_res.job.queue
        ))
      )
      expect(job.id).to eq(insert_res.job.id)

      expect(
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          queue: "other_queue"
        ))
      ).to be_nil
    end

    it "gets a job by state" do
      insert_res = client.insert(job_args)

      job = driver.send(
        :to_job_row,
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          state: [River::JOB_STATE_AVAILABLE, River::JOB_STATE_COMPLETED]
        ))
      )
      expect(job.id).to eq(insert_res.job.id)

      expect(
        driver.job_get_by_kind_and_unique_properties(River::Driver::JobGetByKindAndUniquePropertiesParam.new(
          kind: job_args.kind,
          state: [River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED]
        ))
      ).to be_nil
    end
  end

  describe "#job_insert" do
    it "inserts a job" do
      insert_res = client.insert(SimpleArgs.new(job_num: 1))
      expect(insert_res.job).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now.utc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.utc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )

      # Make sure it made it to the database. Assert only minimally since we're
      # certain it's the same as what we checked above.
      river_job = River::Driver::ActiveRecord::RiverJob.find_by(id: insert_res.job.id)
      expect(river_job).to have_attributes(
        kind: "simple"
      )
    end

    it "schedules a job" do
      target_time = Time.now.utc + 1 * 3600

      insert_res = client.insert(
        SimpleArgs.new(job_num: 1),
        insert_opts: River::InsertOpts.new(scheduled_at: target_time)
      )
      expect(insert_res.job).to have_attributes(
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

    it "inserts in a transaction" do
      insert_res = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        insert_res = client.insert(SimpleArgs.new(job_num: 1))

        river_job = River::Driver::ActiveRecord::RiverJob.find_by(id: insert_res.job.id)
        expect(river_job).to_not be_nil

        raise ActiveRecord::Rollback
      end

      # Not present because the job was rolled back.
      river_job = River::Driver::ActiveRecord::RiverJob.find_by(id: insert_res.job.id)
      expect(river_job).to be_nil
    end
  end

  describe "#job_insert_many" do
    it "inserts multiple jobs" do
      num_inserted = client.insert_many([
        SimpleArgs.new(job_num: 1),
        SimpleArgs.new(job_num: 2)
      ])
      expect(num_inserted).to eq(2)

      job1 = driver.send(:to_job_row, River::Driver::ActiveRecord::RiverJob.first)
      expect(job1).to have_attributes(
        attempt: 0,
        args: {"job_num" => 1},
        created_at: be_within(2).of(Time.now.utc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.utc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )

      job2 = driver.send(:to_job_row, River::Driver::ActiveRecord::RiverJob.offset(1).first)
      expect(job2).to have_attributes(
        attempt: 0,
        args: {"job_num" => 2},
        created_at: be_within(2).of(Time.now.utc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.utc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )
    end

    it "inserts multiple jobs in a transaction" do
      job1 = nil
      job2 = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        num_inserted = client.insert_many([
          SimpleArgs.new(job_num: 1),
          SimpleArgs.new(job_num: 2)
        ])
        expect(num_inserted).to eq(2)

        job1 = driver.send(:to_job_row, River::Driver::ActiveRecord::RiverJob.first)
        job2 = driver.send(:to_job_row, River::Driver::ActiveRecord::RiverJob.offset(1).first)

        raise ActiveRecord::Rollback
      end

      # Not present because the jobs were rolled back.
      expect do
        River::Driver::ActiveRecord::RiverJob.find(job1.id)
      end.to raise_error(ActiveRecord::RecordNotFound)
      expect do
        River::Driver::ActiveRecord::RiverJob.find(job2.id)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "#transaction" do
    it "runs block in a transaction" do
      insert_res = nil

      driver.transaction do
        insert_res = client.insert(SimpleArgs.new(job_num: 1))

        river_job = River::Driver::ActiveRecord::RiverJob.find_by(id: insert_res.job.id)
        expect(river_job).to_not be_nil

        raise ActiveRecord::Rollback
      end

      # Not present because the job was rolled back.
      river_job = River::Driver::ActiveRecord::RiverJob.find_by(id: insert_res.job.id)
      expect(river_job).to be_nil
    end
  end

  describe "#to_job_row" do
    it "converts a database record to `River::JobRow`" do
      now = Time.now.utc
      river_job = River::Driver::ActiveRecord::RiverJob.new(
        id: 1,
        attempt: 1,
        attempted_at: now,
        attempted_by: ["client1"],
        created_at: now,
        args: %({"job_num":1}),
        finalized_at: now,
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: now,
        state: River::JOB_STATE_COMPLETED,
        tags: ["tag1"]
      )

      job_row = driver.send(:to_job_row, river_job)

      expect(job_row).to be_an_instance_of(River::JobRow)
      expect(job_row).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 1,
        attempted_at: now,
        attempted_by: ["client1"],
        created_at: now,
        finalized_at: now,
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: now,
        state: River::JOB_STATE_COMPLETED,
        tags: ["tag1"]
      )
    end

    it "with errors" do
      now = Time.now.utc
      river_job = River::Driver::ActiveRecord::RiverJob.new(
        errors: [JSON.dump(
          {
            at: now,
            attempt: 1,
            error: "job failure",
            trace: "error trace"
          }
        )]
      )

      job_row = driver.send(:to_job_row, river_job)

      expect(job_row.errors.count).to be(1)
      expect(job_row.errors[0]).to be_an_instance_of(River::AttemptError)
      expect(job_row.errors[0]).to have_attributes(
        at: now.floor(0),
        attempt: 1,
        error: "job failure",
        trace: "error trace"
      )
    end
  end
end
