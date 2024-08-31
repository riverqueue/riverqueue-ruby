require "spec_helper"
require_relative "../../../spec/driver_shared_examples"

RSpec.describe River::Driver::ActiveRecord do
  around(:each) { |ex| test_transaction(&ex) }

  let!(:driver) { River::Driver::ActiveRecord.new }
  let(:client) { River::Client.new(driver) }

  before do
    if ENV["RIVER_DEBUG"] == "1" || ENV["RIVER_DEBUG"] == "true"
      ActiveRecord::Base.logger = Logger.new($stdout)
    end
  end

  it_behaves_like "driver shared examples"

  describe "#to_job_row_from_model" do
    it "converts a database record to `River::JobRow` with minimal properties" do
      river_job = River::Driver::ActiveRecord::RiverJob.create(
        id: 1,
        args: %({"job_num":1}),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        state: River::JOB_STATE_AVAILABLE
      )

      job_row = driver.send(:to_job_row_from_model, river_job)

      expect(job_row).to be_an_instance_of(River::JobRow)
      expect(job_row).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 0,
        attempted_at: nil,
        attempted_by: nil,
        created_at: be_within(2).of(Time.now.getutc),
        finalized_at: nil,
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )
    end

    it "converts a database record to `River::JobRow` with all properties" do
      now = Time.now
      river_job = River::Driver::ActiveRecord::RiverJob.create(
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
        tags: ["tag1"],
        unique_key: Digest::SHA256.digest("unique_key_str")
      )

      job_row = driver.send(:to_job_row_from_model, river_job)

      expect(job_row).to be_an_instance_of(River::JobRow)
      expect(job_row).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 1,
        attempted_at: now.getutc,
        attempted_by: ["client1"],
        created_at: now.getutc,
        finalized_at: now.getutc,
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: now.getutc,
        state: River::JOB_STATE_COMPLETED,
        tags: ["tag1"],
        unique_key: Digest::SHA256.digest("unique_key_str")
      )
    end

    it "with errors" do
      now = Time.now.utc
      river_job = River::Driver::ActiveRecord::RiverJob.create(
        args: %({"job_num":1}),
        errors: [JSON.dump(
          {
            at: now,
            attempt: 1,
            error: "job failure",
            trace: "error trace"
          }
        )],
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        state: River::JOB_STATE_AVAILABLE
      )

      job_row = driver.send(:to_job_row_from_model, river_job)

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

  describe "#to_job_row_from_raw" do
    it "converts a database record to `River::JobRow` with minimal properties" do
      river_job = River::Driver::ActiveRecord::RiverJob.insert({
        id: 1,
        args: %({"job_num":1}),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT
      }, returning: Arel.sql("*"))

      job_row = driver.send(:to_job_row_from_raw, river_job)

      expect(job_row).to be_an_instance_of(River::JobRow)
      expect(job_row).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 0,
        attempted_at: nil,
        attempted_by: nil,
        created_at: be_within(2).of(Time.now.getutc),
        finalized_at: nil,
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )
    end

    it "converts a database record to `River::JobRow` with all properties" do
      now = Time.now
      river_job = River::Driver::ActiveRecord::RiverJob.insert({
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
        tags: ["tag1"],
        unique_key: Digest::SHA256.digest("unique_key_str")
      }, returning: Arel.sql("*"))

      job_row = driver.send(:to_job_row_from_raw, river_job)

      expect(job_row).to be_an_instance_of(River::JobRow)
      expect(job_row).to have_attributes(
        id: 1,
        args: {"job_num" => 1},
        attempt: 1,
        attempted_at: be_within(2).of(now.getutc),
        attempted_by: ["client1"],
        created_at: be_within(2).of(now.getutc),
        finalized_at: be_within(2).of(now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(now.getutc),
        state: River::JOB_STATE_COMPLETED,
        tags: ["tag1"],
        unique_key: Digest::SHA256.digest("unique_key_str")
      )
    end

    it "with errors" do
      now = Time.now.utc
      river_job = River::Driver::ActiveRecord::RiverJob.insert({
        args: %({"job_num":1}),
        errors: [JSON.dump(
          {
            at: now,
            attempt: 1,
            error: "job failure",
            trace: "error trace"
          }
        )],
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        state: River::JOB_STATE_AVAILABLE
      }, returning: Arel.sql("*"))

      job_row = driver.send(:to_job_row_from_raw, river_job)

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
