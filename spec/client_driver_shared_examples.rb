# frozen_string_literal: true

require "timeout"
require "riverqueue/testing"

RSpec.shared_examples "PostgreSQL finalized job list plans" do
  it "uses the finalized-time index for single-state listings in both directions" do
    @driver.send(:runtime_execute, <<~SQL)
      INSERT INTO river_job (state, kind, args, finalized_at)
      SELECT (ARRAY['cancelled', 'completed', 'discarded'])[1 + n % 3]::river_job_state,
             'list_plan', '{}', now() + n * interval '1 millisecond'
      FROM generate_series(1, 10000) n
    SQL
    @driver.send(:runtime_execute, "ANALYZE river_job")
    plans = []
    original = @driver.method(:runtime_job_rows)
    @driver.define_singleton_method(:runtime_job_rows) do |suffix|
      plans << runtime_query_rows("EXPLAIN SELECT * FROM river_job #{suffix}").map { |row| row.values.join }.join("\n")
      original.call(suffix)
    end

    %w[cancelled completed discarded].product([:asc, :desc]).each do |state, order|
      jobs = @driver.job_list(River::JobListParams.new(states: [state], sort_by: :finalized_at, sort_order: order, limit: 10))
      expect(jobs.length).to eq(10)
      expect(plans.last).to include("Index Scan", "river_job_state_and_finalized_at_index")
    end
  end
end

RSpec.shared_examples "PostgreSQL rescue concurrency" do
  [:complete, :reclaim].each do |change|
    it "preserves a concurrent #{change} and rescues another stuck job in the batch" do
      now = Time.now.utc
      client = River::Client.new(@driver)
      first, second = 2.times.map do
        row = client.insert(River::JobArgsHash.new("rescue_test", {}),
          insert_opts: River::InsertOpts.new(scheduled_at: now - 120, state: "available")).job
        @driver.job_claim(id: row.id, attempted_by: "old-worker", now: now - 120)
      end
      locked = Queue.new
      release = Queue.new
      writer = Thread.new do
        @driver.transaction do
          if change == :complete
            @driver.job_complete(id: first.id, finalized_at: now, metadata: {"output" => "done"}, now: now)
          else
            @driver.job_set_state_if_running(id: first.id, scheduled_at: now, state: "available", now: now)
            @driver.job_claim(id: first.id, attempted_by: "new-worker", now: now)
          end
          expected = @driver.send(:runtime_query_rows, "SELECT * FROM river_job WHERE id = #{first.id}")
          locked << expected
          release.pop(timeout: 5)
        end
      end

      expected = Timeout.timeout(5) { locked.pop }
      expect(@driver.job_rescue_stuck(horizon: now - 60, max: 1, now: now, retry_policy: River::DefaultClientRetryPolicy.new)).to eq(1)
      expect(@driver.job_get_by_id(second.id).state).to eq("retryable")
      release << true
      writer.value
      expect(@driver.send(:runtime_query_rows, "SELECT * FROM river_job WHERE id = #{first.id}")).to eq(expected)
      expect(@driver.job_rescue_stuck(horizon: now - 60, now: now, retry_policy: River::DefaultClientRetryPolicy.new)).to eq(0)
    ensure
      release << true if release
      writer&.join
    end
  end
end

RSpec.shared_examples "SQL scheduling concurrency" do
  it "skips locked jobs without overwriting a concurrent reschedule" do
    client = River::Client.new(@driver)
    now = Time.now.utc
    first, second = [now - 2, now - 1].map do |scheduled_at|
      client.insert(River::JobArgsHash.new("driver_e2e", {"value" => 1}),
        insert_opts: River::InsertOpts.new(scheduled_at: scheduled_at, state: "scheduled")).job
    end
    locked = Queue.new
    release = Queue.new
    writer = Thread.new do
      @driver.transaction do
        @driver.send(:runtime_execute, "UPDATE river_job SET scheduled_at = #{@driver.send(:runtime_time, now + 60)} WHERE id = #{first.id}")
        locked << true
        release.pop(timeout: 5)
      end
    end

    Timeout.timeout(5) { locked.pop }
    expect(@driver.job_schedule(now: now, max: 1)).to eq(1)
    expect(@driver.job_get_by_id(second.id).state).to eq("available")
    release << true
    writer.value
    expect(@driver.job_get_by_id(first.id)).to have_attributes(state: "scheduled", scheduled_at: be_within(0.001).of(now + 60))
    expect(@driver.job_schedule(now: now)).to eq(0)
  ensure
    release << true if release
    writer&.join
  end
end

RSpec.shared_examples "client driver end to end" do
  it "accepts symbolic identifiers for insertion, uniqueness, filtering, and updates" do
    states = %i[available pending running scheduled].freeze
    args_keys = [:account_id].freeze
    opts = River::InsertOpts.new(queue: :imports, state: :pending,
      unique_opts: River::UniqueOpts.new(by_args: args_keys, by_state: states, by_queue: true))
    first, second = client.insert_many([1, 2].map do |account_id|
      River::InsertManyParams.new(River::JobArgsHash.new(:import, {account_id: account_id}), insert_opts: opts)
    end).map(&:job)
    duplicate = client.insert(River::JobArgsHash.new("import", {account_id: 1, ignored: true}),
      insert_opts: River::InsertOpts.new(queue: "imports", state: "pending",
        unique_opts: River::UniqueOpts.new(by_args: ["account_id"], by_state: states.map(&:to_s), by_queue: true)))

    expect(first).to have_attributes(kind: "import", queue: "imports", state: "pending")
    expect(second.id).not_to eq(first.id)
    expect(duplicate.unique_skipped_as_duplicated).to be true
    expect(duplicate.job.id).to eq(first.id)
    filters = {kinds: [:import].freeze, queues: [:imports].freeze, states: [:pending].freeze}
    expect(client.job_list(River::JobListParams.new(**filters)).jobs.map(&:id)).to eq([first.id, second.id])
    expect(client.job_update(first.id, River::JobUpdateParams.new(state: :available)).state).to eq("available")
    expect(client.job_delete_many(River::JobListParams.new(**filters)).jobs.map(&:id)).to eq([second.id])
    expect(opts.state).to eq(:pending)
  end

  it "accepts symbols in queue administration and publishes queue events" do
    @driver.queue_upsert("imports")
    subscription = client.subscribe(:queue_paused, :queue_resumed)

    expect(client.queue_get(:imports).name).to eq("imports")
    expect(client.queue_update(:imports, metadata: {team: "data"}).metadata).to eq("team" => "data")
    client.queue_pause :imports
    expect(client.queue_get(:imports).paused_at).to be_a(Time)
    expect(subscription.pop.kind).to eq(:queue_paused)
    client.queue_resume :imports
    expect(client.queue_get(:imports).paused_at).to be_nil
    expect(subscription.pop.kind).to eq(:queue_resumed)
    client.queue_add :imports, 1
    expect(client.queue_remove(:imports)).to equal(client)
  ensure
    subscription&.close
  end

  let(:worker) do
    Class.new do
      def self.kind = "driver_e2e"

      def next_retry(_job, _error) = Time.now.utc + 0.05

      def work(job)
        raise "permanent failure" if job.args["fail"]
        raise "temporary failure" if job.args["retry"] && job.attempt == 1

        job.output = {"value" => job.args.fetch("value") * 2}
      end
    end
  end

  let(:client) do
    River::Client.new(@driver, config: River::Config.new(
      fetch_cooldown: 0.001,
      fetch_poll_interval: 0.01,
      queues: {"driver_e2e" => 2},
      workers: River::Workers.new.add(worker)
    ))
  end

  after { client.stop_and_cancel if @driver }

  def e2e_insert(**args)
    client.insert(River::JobArgsHash.new("driver_e2e", args), insert_opts: River::InsertOpts.new(queue: "driver_e2e")).job
  end

  def next_event(subscription)
    Timeout.timeout(5) { subscription.pop }
  end

  it "asserts insertions and executes synchronously inside the caller's transaction" do
    row = nil
    @driver.transaction do
      inserted = River::Testing.inserted_jobs(client, args: {"value" => 9}, kind: "driver_e2e") { e2e_insert(value: 9) }

      expect(inserted.length).to eq(1)
      row = inserted.first
      result = River::Testing.perform_job(client, row.id)

      expect(result).to have_attributes(id: row.id, error: nil, outcome: :completed)
      expect(result.job).to have_attributes(
        attempt: 1,
        attempted_by: [client.id],
        metadata: include("output" => {"value" => 18}),
        state: "completed"
      )
      raise @driver.rollback_exception
    end

    expect(@driver.job_get_by_id(row.id)).to be_nil
  end

  it "drains only the selected queue and returns real worker errors" do
    worker.define_method(:next_retry) { |_job, _error| Time.now.utc + 3_600 }
    [{"value" => 2}, {"fail" => true, "value" => 3}].each do |args|
      client.insert(River::JobArgsHash.new("driver_e2e", args), insert_opts: River::InsertOpts.new(
        queue: "driver_e2e", scheduled_at: Time.now.utc - 1, state: "available"
      ))
    end

    client.insert(River::JobArgsHash.new("driver_e2e", {"value" => 4}))
    results = River::Testing.drain(client, queue: "driver_e2e")

    expect(results.map(&:outcome)).to eq([:completed, :retried])
    expect(results.last.error).to have_attributes(message: "permanent failure")
    expect(client.job_list(River::JobListParams.new(queues: ["default"])).jobs.first.state).to eq("available")
  end

  it "rolls back enqueues and hides uncommitted jobs from another connection" do
    rolled_back = nil
    @driver.transaction do
      rolled_back = e2e_insert(value: 1)
      observed = Thread.new { @driver.job_get_by_id(rolled_back.id) }.value

      expect(observed).to be_nil
      raise @driver.rollback_exception
    end

    expect(@driver.job_get_by_id(rolled_back.id)).to be_nil
    expect(client.job_list.jobs).to be_empty
  end

  it "works committed bulk inserts in background threads and persists output" do
    subscription = client.subscribe(River::EVENT_JOB_COMPLETED)
    rows = @driver.transaction do
      client.insert_many((1..3).map do |value|
        River::InsertManyParams.new(River::JobArgsHash.new("driver_e2e", {"value" => value}),
          insert_opts: River::InsertOpts.new(queue: "driver_e2e"))
      end).map(&:job)
    end

    client.start
    events = rows.map { next_event(subscription) }

    expect(events.map { |event| event.job.id }).to match_array(rows.map(&:id))
    rows.each do |row|
      expect(client.job_get(row.id)).to have_attributes(
        id: row.id,
        attempt: 1,
        attempted_by: [client.id],
        finalized_at: be_a(Time),
        metadata: include("output" => {"value" => row.args.fetch("value") * 2}),
        state: River::JOB_STATE_COMPLETED
      )
    end

    client.stop

    expect(client).to be_stopped
  ensure
    subscription&.close
  end

  it "retries a failed attempt, records its error, and then completes" do
    subscription = client.subscribe(River::EVENT_JOB_COMPLETED, River::EVENT_JOB_FAILED)
    row = e2e_insert(retry: true, value: 7)
    client.start

    expect(next_event(subscription)).to have_attributes(kind: River::EVENT_JOB_FAILED)
    expect(next_event(subscription)).to have_attributes(kind: River::EVENT_JOB_COMPLETED)
    expect(client.job_get(row.id)).to have_attributes(
      attempt: 2,
      errors: contain_exactly(have_attributes(attempt: 1, error: "temporary failure")),
      metadata: include("output" => {"value" => 14}),
      state: River::JOB_STATE_COMPLETED
    )
  ensure
    subscription&.close
  end

  it "discards exhausted jobs and supports retry and cancellation administration" do
    subscription = client.subscribe(River::EVENT_JOB_FAILED)
    row = client.insert(River::JobArgsHash.new("driver_e2e", {"fail" => true}),
      insert_opts: River::InsertOpts.new(max_attempts: 1, queue: "driver_e2e")).job
    client.start

    expect(next_event(subscription).job).to have_attributes(
      id: row.id,
      errors: contain_exactly(have_attributes(error: "permanent failure")),
      finalized_at: be_a(Time),
      state: River::JOB_STATE_DISCARDED
    )
    client.stop

    expect(client.job_retry(row.id)).to have_attributes(finalized_at: nil, max_attempts: 2, state: River::JOB_STATE_AVAILABLE)
    expect(client.job_cancel(row.id)).to have_attributes(finalized_at: be_a(Time), state: River::JOB_STATE_CANCELLED)
    expect(client.job_delete(row.id)).to have_attributes(id: row.id)
    expect(@driver.job_get_by_id(row.id)).to be_nil
  ensure
    subscription&.close
  end
end
