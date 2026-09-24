# frozen_string_literal: true

require_relative "driver_runtime_shared_examples"

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

shared_examples "driver shared examples" do
  it_behaves_like "driver job state machine"
  it_behaves_like "driver queue and leadership state"

  it "merges metadata shallowly, preserving nulls and literal keys on both databases" do
    job = client.insert(SimpleArgs.new(job_num: 1), insert_opts: River::InsertOpts.new(
      metadata: {"keep" => 1, "nested" => {"old" => true}, "nullable" => 2}
    )).job
    updates = {'a"b' => "literal", "a.b" => [1, true], "a\\b" => false, "nested" => {"new" => true}, "nullable" => nil}

    driver.job_metadata_merge(job.id, updates)

    expect(client.job_get(job.id).metadata.to_h).to eq(job.metadata.to_h.merge(updates))
  end

  it "does not clean up a finalized job retried after cleanup selected it" do
    job = client.insert(SimpleArgs.new(job_num: 1)).job
    client.job_update(job.id, River::JobUpdateParams.new(finalized_at: Time.now.utc - 120, state: River::JOB_STATE_COMPLETED))
    driver.define_singleton_method(:runtime_query_rows) do |sql|
      rows = super(sql)
      job_retry(job.id) if sql.start_with?("SELECT id FROM river_job WHERE")

      rows
    end

    expect(driver.job_delete_finalized(retention: {River::JOB_STATE_COMPLETED => 60})).to eq(0)
    expect(client.job_get(job.id).state).to eq(River::JOB_STATE_AVAILABLE)
  end

  it "keeps static driver constants shareable across Ractor boundaries" do
    values = %i[SQLITE_CONFLICT_WHERE SQLITE_JOB_COLUMNS SQLITE_UNIQUE_NONCE_KEY]
      .map { |name| driver.class.const_get(name, false) }

    expect(values).to all(satisfy { |value| Ractor.shareable?(value) })
  end

  it "implements the worker runtime SQL primitives" do
    queue = driver.queue_upsert("runtime-primitives", metadata: {"source" => "spec"})

    expect(queue).to have_attributes(metadata: {"source" => "spec"}, name: "runtime-primitives")
    expect(driver.queue_list(max: 10).map(&:name)).to include("runtime-primitives")
    expect(driver.job_list(River::JobListParams.new(limit: 1))).to be_an(Array)
    expect(driver.send(:runtime_job_list_without_params)).to be_an(Array)
    expect(driver.send(:runtime_postgres?)).to satisfy { |value| value == true || value == false }
    expect(driver.send(:runtime_quote, "value")).to be_a(String)
    expect(driver.send(:runtime_unique_violation_class)).to be <= StandardError
    expect(driver.send(:runtime_value, {"id" => 1}, :id)).to eq(1)
  end

  describe "unique insertion" do
    it "inserts a unique job once" do
      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        unique_opts: River::UniqueOpts.new(
          by_queue: true
        )
      )

      insert_res = client.insert(args)

      expect(insert_res).to have_attributes(
        job: be_a(River::JobRow),
        unique_skipped_as_duplicated: be(false)
      )
      original_job = insert_res.job

      insert_res = client.insert(args)

      expect(insert_res).to have_attributes(
        job: have_attributes(id: original_job.id),
        unique_skipped_as_duplicated: be(true)
      )
    end

    it "inserts a unique job with custom states" do
      client = River::Client.new(driver)

      args = SimpleArgsWithInsertOpts.new(job_num: 1)
      args.insert_opts = River::InsertOpts.new(
        unique_opts: River::UniqueOpts.new(
          by_queue: true,
          by_state: [River::JOB_STATE_AVAILABLE, River::JOB_STATE_PENDING, River::JOB_STATE_RUNNING, River::JOB_STATE_SCHEDULED]
        )
      )

      insert_res = client.insert(args)

      expect(insert_res).to have_attributes(
        job: be_a(River::JobRow),
        unique_skipped_as_duplicated: be(false)
      )
      original_job = insert_res.job

      insert_res = client.insert(args)

      expect(insert_res).to have_attributes(
        job: have_attributes(id: original_job.id),
        unique_skipped_as_duplicated: be(true)
      )
    end
  end

  describe "#job_get_by_id" do
    let(:job_args) { SimpleArgs.new(job_num: 1) }

    it "gets a job by ID" do
      insert_res = client.insert(job_args)
      expect(driver.job_get_by_id(insert_res.job.id)).to_not be nil
    end

    it "returns nil on not found" do
      expect(driver.job_get_by_id(-1)).to be nil
    end
  end

  describe "#job_insert" do
    it "inserts a job" do
      insert_res = client.insert(SimpleArgs.new(job_num: 1))

      expect(insert_res).to have_attributes(
        job: have_attributes(
          args: {"job_num" => 1},
          attempt: 0,
          created_at: be_within(2).of(Time.now.getutc),
          kind: "simple",
          max_attempts: River::MAX_ATTEMPTS_DEFAULT,
          priority: River::PRIORITY_DEFAULT,
          queue: River::QUEUE_DEFAULT,
          scheduled_at: be_within(2).of(Time.now.getutc),
          state: River::JOB_STATE_AVAILABLE,
          tags: []
        ),
        unique_skipped_as_duplicated: (be false)
      )

      # Make sure it made it to the database. Assert only minimally since we're
      # certain it's the same as what we checked above.
      job = driver.job_get_by_id(insert_res.job.id)

      expect(job).to have_attributes(
        kind: "simple"
      )
    end

    it "schedules a job" do
      target_time = Time.now.getutc + 1 * 3600

      insert_res = client.insert(
        SimpleArgs.new(job_num: 1),
        insert_opts: River::InsertOpts.new(scheduled_at: target_time)
      )

      expect(insert_res).to have_attributes(
        job: have_attributes(
          scheduled_at: be_within(2).of(target_time),
          state: River::JOB_STATE_SCHEDULED
        ),
        unique_skipped_as_duplicated: (be false)
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

      expect(insert_res).to have_attributes(
        job: have_attributes(
          max_attempts: 23,
          priority: 2,
          queue: "job_custom_queue",
          tags: ["job_custom"]
        ),
        unique_skipped_as_duplicated: (be false)
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

      expect(insert_res).to have_attributes(
        job: have_attributes(
          max_attempts: 17,
          priority: 3,
          queue: "my_queue",
          tags: ["custom"]
        ),
        unique_skipped_as_duplicated: (be false)
      )
    end

    it "inserts with job args hash" do
      insert_res = client.insert(River::JobArgsHash.new("hash_kind", {
        job_num: 1
      }))
      expect(insert_res).to have_attributes(
        job: have_attributes(
          args: {"job_num" => 1},
          kind: "hash_kind"
        ),
        unique_skipped_as_duplicated: (be false)
      )
    end

    it "inserts in a transaction" do
      insert_res = nil

      driver.transaction do
        insert_res = client.insert(SimpleArgs.new(job_num: 1))

        job = driver.job_get_by_id(insert_res.job.id)

        expect(job).to_not be_nil
        expect(insert_res.unique_skipped_as_duplicated).to be false

        raise driver.rollback_exception
      end

      # Not present because the job was rolled back.
      job = driver.job_get_by_id(insert_res.job.id)

      expect(job).to be_nil
    end

    it "inserts a unique job" do
      insert_params = River::Driver::JobInsertParams.new(
        encoded_args: JSON.dump({"job_num" => 1}),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: Time.now.getutc,
        state: River::JOB_STATE_AVAILABLE,
        tags: nil,
        unique_key: "unique_key",
        unique_states: "00000001"
      )

      job_row, unique_skipped_as_duplicated = driver.job_insert(insert_params)

      expect(job_row).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: [],
        unique_key: "unique_key",
        unique_states: [::River::JOB_STATE_AVAILABLE]
      )
      expect(unique_skipped_as_duplicated).to be false

      # second insertion should be skipped
      job_row, unique_skipped_as_duplicated = driver.job_insert(insert_params)

      expect(job_row).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: [],
        unique_key: "unique_key",
        unique_states: [::River::JOB_STATE_AVAILABLE]
      )
      expect(unique_skipped_as_duplicated).to be true
    end
  end

  describe "#job_insert_many" do
    it "inserts multiple jobs" do
      inserted = client.insert_many([
        SimpleArgs.new(job_num: 1),
        SimpleArgs.new(job_num: 2)
      ])

      expect(inserted.length).to eq(2)
      expect(inserted[0]).to have_attributes(
        job: have_attributes(args: {"job_num" => 1}),
        unique_skipped_as_duplicated: false
      )
      expect(inserted[1]).to have_attributes(
        job: have_attributes(args: {"job_num" => 2}),
        unique_skipped_as_duplicated: false
      )

      jobs = driver.job_list

      expect(jobs.count).to be 2

      expect(jobs[0]).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )

      expect(jobs[1]).to have_attributes(
        args: {"job_num" => 2},
        attempt: 0,
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )
    end

    it "inserts multiple jobs in a transaction" do
      jobs = nil

      driver.transaction do
        inserted = client.insert_many([
          SimpleArgs.new(job_num: 1),
          SimpleArgs.new(job_num: 2)
        ])

        expect(inserted.length).to eq(2)
        expect(inserted[0]).to have_attributes(
          job: have_attributes(args: {"job_num" => 1}),
          unique_skipped_as_duplicated: false
        )
        expect(inserted[1]).to have_attributes(
          job: have_attributes(args: {"job_num" => 2}),
          unique_skipped_as_duplicated: false
        )

        jobs = driver.job_list

        expect(jobs.count).to be 2

        raise driver.rollback_exception
      end

      # Not present because the jobs were rolled back.
      expect(driver.job_get_by_id(jobs[0].id)).to be nil
      expect(driver.job_get_by_id(jobs[1].id)).to be nil
    end
  end

  describe "#job_list" do
    let(:job_args) { SimpleArgs.new(job_num: 1) }

    it "gets a job by ID" do
      insert_res1 = client.insert(job_args)
      insert_res2 = client.insert(job_args)

      jobs = driver.job_list

      expect(jobs.count).to be 2

      expect(jobs[0].id).to be insert_res1.job.id
      expect(jobs[1].id).to be insert_res2.job.id
    end

    it "returns nil on not found" do
      expect(driver.job_get_by_id(-1)).to be nil
    end
  end

  describe "#transaction" do
    it "runs block in a transaction" do
      insert_res = nil

      driver.transaction do
        insert_res = client.insert(SimpleArgs.new(job_num: 1))

        job = driver.job_get_by_id(insert_res.job.id)

        expect(job).to_not be_nil

        raise driver.rollback_exception
      end

      # Not present because the job was rolled back.
      job = driver.job_get_by_id(insert_res.job.id)

      expect(job).to be_nil
    end
  end
end
