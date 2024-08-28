require "spec_helper"
require_relative "../../../spec/driver_shared_examples"

RSpec.describe River::Driver::Sequel do
  around(:each) { |ex| test_transaction(&ex) }

  let!(:driver) { River::Driver::Sequel.new(DB) }
  let(:client) { River::Client.new(driver) }

  it_behaves_like "driver shared examples"

  describe "#to_job_row" do
    it "converts a database record to `River::JobRow` with minimal properties" do
      river_job = DB[:river_job].returning.insert_select({
        id: 1,
        args: %({"job_num":1}),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT
      })

      job_row = driver.send(:to_job_row, river_job)

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
      river_job = DB[:river_job].returning.insert_select({
        id: 1,
        attempt: 1,
        attempted_at: now,
        attempted_by: ::Sequel.pg_array(["client1"]),
        created_at: now,
        args: %({"job_num":1}),
        finalized_at: now,
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: now,
        state: River::JOB_STATE_COMPLETED,
        tags: ::Sequel.pg_array(["tag1"]),
        unique_key: ::Sequel.blob(Digest::SHA256.digest("unique_key_str"))
      })

      job_row = driver.send(:to_job_row, river_job)

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
      river_job = DB[:river_job].returning.insert_select({
        args: %({"job_num":1}),
        errors: ::Sequel.pg_array([
          ::Sequel.pg_json_wrap({
            at: now,
            attempt: 1,
            error: "job failure",
            trace: "error trace"
          })
        ]),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        state: River::JOB_STATE_AVAILABLE
      })

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
