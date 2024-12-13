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
      expect(insert_res.job).to_not be_nil
      expect(insert_res.unique_skipped_as_duplicated).to be false
      original_job = insert_res.job

      insert_res = client.insert(args)
      expect(insert_res.job.id).to eq(original_job.id)
      expect(insert_res.unique_skipped_as_duplicated).to be true
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
      expect(insert_res.job).to have_attributes(
        args: {"job_num" => 1},
        attempt: 0,
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )
      expect(insert_res.unique_skipped_as_duplicated).to be false

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
      expect(insert_res.job).to have_attributes(
        scheduled_at: be_within(2).of(target_time),
        state: River::JOB_STATE_SCHEDULED
      )
      expect(insert_res.unique_skipped_as_duplicated).to be false
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
      expect(insert_res.unique_skipped_as_duplicated).to be false
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
      expect(insert_res.unique_skipped_as_duplicated).to be false
    end

    it "inserts with job args hash" do
      insert_res = client.insert(River::JobArgsHash.new("hash_kind", {
        job_num: 1
      }))
      expect(insert_res.job).to have_attributes(
        args: {"job_num" => 1},
        kind: "hash_kind"
      )
      expect(insert_res.unique_skipped_as_duplicated).to be false
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
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: Time.now.getutc,
        state: River::JOB_STATE_AVAILABLE,
        unique_key: "unique_key",
        unique_states: "00000001",
        tags: nil
      )

      job_row, unique_skipped_as_duplicated = driver.job_insert(insert_params)
      expect(job_row).to have_attributes(
        attempt: 0,
        args: {"job_num" => 1},
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
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
        attempt: 0,
        args: {"job_num" => 1},
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
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
      expect(inserted[0].job).to have_attributes(args: {"job_num" => 1})
      expect(inserted[0].unique_skipped_as_duplicated).to eq false
      expect(inserted[1].job).to have_attributes(args: {"job_num" => 2})
      expect(inserted[1].unique_skipped_as_duplicated).to eq false

      jobs = driver.job_list
      expect(jobs.count).to be 2

      expect(jobs[0]).to have_attributes(
        attempt: 0,
        args: {"job_num" => 1},
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
        scheduled_at: be_within(2).of(Time.now.getutc),
        state: River::JOB_STATE_AVAILABLE,
        tags: []
      )

      expect(jobs[1]).to have_attributes(
        attempt: 0,
        args: {"job_num" => 2},
        created_at: be_within(2).of(Time.now.getutc),
        kind: "simple",
        max_attempts: River::MAX_ATTEMPTS_DEFAULT,
        queue: River::QUEUE_DEFAULT,
        priority: River::PRIORITY_DEFAULT,
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
        expect(inserted[0].unique_skipped_as_duplicated).to eq false
        expect(inserted[0].job).to have_attributes(args: {"job_num" => 1})
        expect(inserted[1].unique_skipped_as_duplicated).to eq false
        expect(inserted[1].job).to have_attributes(args: {"job_num" => 2})

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
