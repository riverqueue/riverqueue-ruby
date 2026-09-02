# frozen_string_literal: true

class DriverRuntimeArgs
  def initialize(value)
    @value = value
  end

  def kind = "driver_runtime"

  def to_json = JSON.dump(value: @value)
end

RSpec.shared_examples "driver job state machine" do
  let(:client) { River::Client.new(driver) }
  let(:now) { Time.utc(2026, 1, 2, 3, 4, 5) }

  it "completes running jobs, merges metadata, and ignores missing or finished jobs" do
    row = insert_job(1, metadata: {"original" => true}, scheduled_at: now - 1)
    driver.job_claim(id: row.id, attempted_by: "test", now: now)
    expect(driver.job_complete(id: row.id.to_s, finalized_at: now, metadata: {"result" => 42}, now: now)).to have_attributes(
      id: row.id, metadata: include("original" => true, "result" => 42), state: "completed"
    )
    expect(driver.job_complete(id: row.id, finalized_at: now)).to be_nil
    expect(driver.job_complete(id: -1, finalized_at: now)).to be_nil
  end

  it "leaves cancellation-marked jobs for normal cancellation handling" do
    row = insert_job(1, scheduled_at: now - 1)
    driver.job_claim(id: row.id, attempted_by: "test", now: now)
    driver.job_metadata_merge(row.id, "cancel_attempted_at" => nil)
    expect(driver.job_complete(id: row.id, finalized_at: now)).to eq(:cancelled)
    expect(driver.job_get_by_id(row.id).state).to eq("running")
    driver.transaction do
      expect(driver.job_complete(id: row.id, finalized_at: now)).to eq(:cancelled)
      raise driver.rollback_exception
    end
  end

  it "rolls back transactional completion" do
    row = insert_job(1, scheduled_at: now - 1)
    driver.job_claim(id: row.id, attempted_by: "test", now: now)
    driver.transaction do
      expect(driver.job_complete(id: row.id, finalized_at: now).state).to eq("completed")
      raise driver.rollback_exception
    end
    expect(driver.job_get_by_id(row.id).state).to eq("running")
  end

  it "looks up cancellation markers for a batch, excluding missing and uncancelled jobs" do
    cancelled = insert_job(1)
    unmarked = insert_job(2)
    null_marker = insert_job(3)
    driver.job_cancel(cancelled.id)
    driver.job_metadata_merge(null_marker.id, "cancel_attempted_at" => nil)
    expect(driver.job_get_cancelled_ids([])).to eq([])
    expect(driver.job_get_cancelled_ids([cancelled.id, unmarked.id, null_marker.id, -1, cancelled.id])).to contain_exactly(cancelled.id, null_marker.id)
    driver.transaction do
      driver.job_metadata_merge(unmarked.id, "cancel_attempted_at" => "now")
      expect(driver.job_get_cancelled_ids([unmarked.id])).to eq([unmarked.id])
      raise driver.rollback_exception
    end
    expect(driver.job_get_cancelled_ids([unmarked.id])).to eq([])
  end

  [:id, :scheduled_at, :finalized_at].product([:asc, :desc]).each do |sort_by, sort_order|
    it "paginates #{sort_by} #{sort_order} through ties, nulls, and deleted cursor jobs" do
      jobs = [20, 10, 20, 0, 30, 10].map.with_index do |offset, i|
        row = insert_job(i, scheduled_at: now + offset)
        driver.job_update(row.id, River::JobUpdateParams.new(state: "completed", finalized_at: now + offset)) if i < 4
        driver.job_get_by_id(row.id)
      end
      present, missing = jobs.partition { |job| !job.public_send(sort_by).nil? }
      expected = present.sort_by { |job| [job.public_send(sort_by), job.id] }
      expected.reverse! if sort_order == :desc
      missing.sort_by!(&:id)
      missing.reverse! if sort_order == :desc
      expected.concat(missing)

      cursor = nil
      actual = []
      jobs.length.times do
        page = client.job_list(River::JobListParams.new(after: cursor, ids: jobs.map(&:id), limit: 1, sort_by: sort_by, sort_order: sort_order))
        expect(page.jobs.length).to eq(1)
        actual << page.jobs.first.id
        cursor = page.last_cursor
        driver.job_delete(page.jobs.first.id) if actual.length.odd?
      end
      expect(actual).to eq(expected.map(&:id))
      expect(client.job_list(River::JobListParams.new(after: cursor, ids: jobs.map(&:id), sort_by: sort_by, sort_order: sort_order)).jobs).to be_empty
    end
  end

  it "lists complete rows without per-job lookups" do
    row = insert_job(1)
    driver.define_singleton_method(:job_get_by_id) { |_id| raise "listing must use one snapshot" }

    expect(client.job_list(River::JobListParams.new(ids: [row.id])).jobs).to contain_exactly(have_attributes(id: row.id, args: row.args))
  end

  [nil, "cancelled", "completed", "discarded"].product([:asc, :desc]).each do |state, sort_order|
    it "paginates #{state || "scheduled"} timestamps #{sort_order} with millisecond ties and reusable timezone cursors" do
      sort_by = state ? :finalized_at : :scheduled_at
      jobs = [123, 124, 123, 122].map do |milliseconds|
        timestamp = now + Rational(milliseconds, 1_000)
        row = insert_job(1, scheduled_at: timestamp, metadata: {"tenant" => 42})
        driver.job_update(row.id, River::JobUpdateParams.new(state: state, finalized_at: timestamp)) if state
        row
      end
      expected = jobs.sort_by { |job| [job.scheduled_at, job.id] }.map(&:id)
      expected.reverse! if sort_order == :desc
      cursor = nil
      actual = []
      jobs.length.times do
        params = River::JobListParams.new(after: cursor, limit: 1, metadata: {tenant: 42},
          sort_by: sort_by, sort_order: sort_order, states: state ? [state] : nil).freeze
        page = client.job_list(params)
        expect(page.jobs.length).to eq(1)
        expect(client.job_list(params).jobs.map(&:id)).to eq(page.jobs.map(&:id))
        actual << page.jobs.first.id
        cursor = page.last_cursor.with(value: page.last_cursor.value.getlocal("+05:30").freeze)
      end
      expect(actual).to eq(expected)
      expect(cursor.value.utc_offset).to eq(19_800)
    end
  end

  it "matches metadata as JSON values, including nulls, nested objects, and literal keys" do
    values = [nil, false, true, 1, 1.5, "1", "true", "null", [], {}, [1, {"a" => 2}], {"a" => 1, "b" => [false, nil]}]
    rows = values.map { |value| insert_job(1, metadata: {"value" => value}) }
    insert_job(1, metadata: {})
    values.zip(rows).each do |value, row|
      expect(driver.job_list(River::JobListParams.new(metadata: {value: value})).map(&:id)).to eq([row.id])
    end
    expect(driver.job_list(River::JobListParams.new(metadata: {value: 1.0})).map(&:id)).to eq([rows[3].id])
    expect(driver.job_list(River::JobListParams.new(metadata: {value: {"b" => [false, nil], "a" => 1}})).map(&:id)).to eq([rows.last.id])

    key = "literal.key[0]\"\\"
    row = insert_job(1, metadata: {key => "quoted\"\\value"})
    expect(driver.job_list(River::JobListParams.new(metadata: {key => "quoted\"\\value"})).map(&:id)).to eq([row.id])
  end

  it "claims only the requested eligible job and requires explicit early execution" do
    other = insert_job(1, scheduled_at: now - 1)
    future = insert_job(2, scheduled_at: now + 60, state: River::JOB_STATE_SCHEDULED)

    expect(driver.job_claim(id: future.id, attempted_by: "test", now: now)).to be_nil
    claimed = driver.job_claim(id: future.id, allow_scheduled: true, attempted_by: "test", now: now)

    expect(claimed).to have_attributes(
      id: future.id, attempt: 1, attempted_at: be_within(0.001).of(now), attempted_by: ["test"], scheduled_at: be_within(0.001).of(now + 60), state: "running"
    )
    expect(driver.job_get_by_id(other.id).state).to eq("available")
    expect(driver.job_claim(id: future.id, allow_scheduled: true, attempted_by: "test", now: now)).to be_nil
    expect(driver.job_claim(id: -1, attempted_by: "test", now: now)).to be_nil
    expect(driver.job_claim(id: other.id, attempted_by: "test", now: now).id).to eq(other.id)
  end

  it "claims due scheduled and retryable jobs, but never pending or terminal jobs" do
    %w[scheduled retryable pending cancelled completed discarded].each do |state|
      row = insert_job(1, scheduled_at: now - 1, state: "pending")
      driver.job_update(row.id, River::JobUpdateParams.new(
        finalized_at: %w[cancelled completed discarded].include?(state) ? now : nil,
        state: state
      ))
      claimed = driver.job_claim(id: row.id, attempted_by: "test", now: now)
      if %w[scheduled retryable].include?(state)
        expect(claimed).to have_attributes(id: row.id, attempt: 1, state: "running")
      else
        expect(claimed).to be_nil
      end
    end
  end

  def insert_job(value, **options)
    if options.key?(:scheduled_at) && !options.key?(:state)
      options[:state] = River::JOB_STATE_AVAILABLE
    end

    client.insert(DriverRuntimeArgs.new(value), insert_opts: River::InsertOpts.new(**options)).job
  end

  it "cancels waiting jobs and leaves already finalized jobs unchanged" do
    job = insert_job(1)

    expect(driver.job_cancel(job.id, now: now)).to have_attributes(
      id: job.id, finalized_at: be_within(0.001).of(now), state: River::JOB_STATE_CANCELLED
    )
    expect(driver.job_cancel(job.id, now: now + 10)).to have_attributes(finalized_at: be_within(0.001).of(now))
    expect(driver.job_cancel(-1)).to be_nil
  end

  it "deletes waiting jobs but protects running jobs" do
    waiting = insert_job(1, scheduled_at: now + 60)
    running = insert_job(2, scheduled_at: now - 1)
    driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "default")

    expect(driver.job_delete(waiting.id)).to have_attributes(id: waiting.id)
    expect(driver.job_get_by_id(waiting.id)).to be_nil
    expect(driver.job_delete(running.id)).to have_attributes(id: running.id, state: River::JOB_STATE_RUNNING)
    expect(driver.job_delete(-1)).to be_nil
    expect(driver.job_delete_if_running(running.id)).to be true
    expect(driver.job_delete_if_running(running.id)).to be false
  end

  it "bulk deletes only matching non-running jobs and returns their rows" do
    waiting = insert_job(1, queue: "one", scheduled_at: now + 60)
    running = insert_job(2, queue: "one", scheduled_at: now - 1)
    untouched = insert_job(3, queue: "two")
    driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "one")

    expect(driver.job_delete_many(River::JobListParams.new(queues: ["one"]))).to contain_exactly(have_attributes(id: waiting.id))
    expect(driver.job_list.map(&:id)).to match_array([running.id, untouched.id])
    expect(driver.job_delete_if_running(untouched.id)).to be false
  end

  it "retries exhausted finalized jobs but does not reset active attempts" do
    job = insert_job(1, max_attempts: 1, scheduled_at: now - 1)
    driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "default")

    expect(driver.job_retry(job.id, now: now)).to have_attributes(attempt: 1, state: River::JOB_STATE_RUNNING)
    driver.job_set_state_if_running(id: job.id, finalized_at: now, state: River::JOB_STATE_DISCARDED)

    expect(driver.job_retry(job.id, now: now + 10)).to have_attributes(
      attempt: 1, finalized_at: nil, max_attempts: 2,
      scheduled_at: be_within(0.001).of(now + 10), state: River::JOB_STATE_AVAILABLE
    )
    expect(driver.job_retry(-1)).to be_nil
  end

  it "round trips attempt errors, metadata, and nullable update fields" do
    job = insert_job(1)
    error = River::AttemptError.new(at: now, attempt: 1, error: "failure", trace: "worker.rb:42")
    updated = driver.job_update(job.id, River::JobUpdateParams.new(
      attempt: 1, attempted_at: now, attempted_by: ["one", "two"], errors: [error],
      metadata: {"nested" => {"ready" => true}}
    ))

    expect(updated).to have_attributes(
      attempt: 1, attempted_at: be_within(0.001).of(now), attempted_by: ["one", "two"],
      errors: contain_exactly(have_attributes(at: be_within(0.001).of(now), attempt: 1, error: "failure", trace: "worker.rb:42")),
      metadata: {"nested" => {"ready" => true}}
    )
    expect(updated.attempted_by).to be_an_instance_of(Array)
    expect(updated.metadata).to be_an_instance_of(Hash)
    expect(driver.job_update(job.id, River::JobUpdateParams.new(attempted_at: nil))).to have_attributes(attempted_at: nil, attempted_by: ["one", "two"])
    expect(driver.job_update(job.id, River::JobUpdateParams.new)).to have_attributes(id: job.id)
    expect(driver.job_update(-1, River::JobUpdateParams.new(attempt: 1))).to be_nil
  end

  it "completes running jobs with merged metadata and ignores repeated completion" do
    job = insert_job(1, metadata: {"keep" => true}, scheduled_at: now - 1)
    driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "default")
    completed = driver.job_set_state_if_running(id: job.id, finalized_at: now,
      metadata: {"output" => {"value" => 2}}, state: River::JOB_STATE_COMPLETED)

    expect(completed).to have_attributes(
      finalized_at: be_within(0.001).of(now),
      metadata: include("keep" => true, "output" => {"value" => 2}),
      state: River::JOB_STATE_COMPLETED
    )
    expect(driver.job_set_state_if_running(id: job.id, state: River::JOB_STATE_AVAILABLE)).to be_nil
  end

  it "paginates job IDs in both directions with consistent filters" do
    jobs = (1..3).map { |value| insert_job(value) }

    expect(driver.job_list(River::JobListParams.new(after_id: jobs[0].id, limit: 1))).to contain_exactly(have_attributes(id: jobs[1].id))
    expect(driver.job_list(River::JobListParams.new(after_id: jobs[2].id, limit: 1, sort_order: :desc))).to contain_exactly(have_attributes(id: jobs[1].id))
    expect(driver.job_list(River::JobListParams.new(ids: [jobs[0].id], kinds: ["driver_runtime"], states: [River::JOB_STATE_AVAILABLE])))
      .to contain_exactly(have_attributes(id: jobs[0].id))
  end

  it "claims only eligible jobs from the requested queue" do
    eligible = insert_job(1, queue: "work", scheduled_at: now - 1, state: River::JOB_STATE_AVAILABLE)
    future = insert_job(2, queue: "work", scheduled_at: now + 60, state: River::JOB_STATE_AVAILABLE)
    other_queue = insert_job(3, queue: "other", scheduled_at: now - 1, state: River::JOB_STATE_AVAILABLE)
    cancelled = insert_job(4, queue: "work", scheduled_at: now - 1, state: River::JOB_STATE_AVAILABLE)
    client.job_update(cancelled.id, River::JobUpdateParams.new(finalized_at: now, state: River::JOB_STATE_CANCELLED))

    claimed = driver.job_get_available(attempted_by: "worker", max: 10, now: now, queue: "work")

    expect(claimed.map(&:id)).to eq([eligible.id])
    expect(claimed.first).to have_attributes(attempt: 1, attempted_by: ["worker"], state: River::JOB_STATE_RUNNING)
    expect(driver.job_get_by_id(future.id)).to have_attributes(state: River::JOB_STATE_AVAILABLE)
    expect(driver.job_get_by_id(other_queue.id)).to have_attributes(state: River::JOB_STATE_AVAILABLE)
    expect(driver.job_get_by_id(cancelled.id)).to have_attributes(state: River::JOB_STATE_CANCELLED)
  end

  it "claims by priority, scheduled time, and ID while respecting max" do
    low = insert_job(1, priority: 4, queue: "work", scheduled_at: now - 30)
    later = insert_job(2, priority: 1, queue: "work", scheduled_at: now - 10)
    earlier = insert_job(3, priority: 1, queue: "work", scheduled_at: now - 20)

    first_claim = driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "work")
    second_claim = driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "work")

    expect(first_claim.map(&:id)).to eq([earlier.id])
    expect(second_claim.map(&:id)).to eq([later.id])
    expect(driver.job_get_by_id(low.id)).to have_attributes(state: River::JOB_STATE_AVAILABLE)
  end

  it "does not transition a job that is no longer running" do
    inserted = insert_job(1)

    expect(driver.job_set_state_if_running(id: inserted.id, state: River::JOB_STATE_COMPLETED)).to be_nil
    expect(driver.job_get_by_id(inserted.id)).to have_attributes(state: River::JOB_STATE_AVAILABLE)
  end

  it "lets a remote cancellation win over a retry transition" do
    inserted = insert_job(1, scheduled_at: now - 1)
    running = driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: inserted.queue).first
    driver.job_cancel(running.id, now: now)

    updated = driver.job_set_state_if_running(
      id: running.id,
      now: now,
      scheduled_at: now + 60,
      state: River::JOB_STATE_RETRYABLE
    )

    expect(updated).to have_attributes(finalized_at: be_within(0.001).of(now), state: River::JOB_STATE_CANCELLED)
  end

  it "promotes due scheduled and retryable jobs up to max" do
    scheduled = insert_job(1, scheduled_at: now - 2, state: River::JOB_STATE_SCHEDULED)
    retryable = insert_job(2, scheduled_at: now - 1, state: River::JOB_STATE_RETRYABLE)
    future = insert_job(3, scheduled_at: now + 60, state: River::JOB_STATE_SCHEDULED)

    expect(driver.job_schedule(max: 1, now: now)).to eq(1)
    expect(driver.job_get_by_id(scheduled.id)).to have_attributes(state: River::JOB_STATE_AVAILABLE)
    expect(driver.job_get_by_id(retryable.id)).to have_attributes(state: River::JOB_STATE_RETRYABLE)
    expect(driver.job_get_by_id(future.id)).to have_attributes(state: River::JOB_STATE_SCHEDULED)
  end

  it "discards a scheduled job whose unique key conflicts during promotion" do
    states = [
      River::JOB_STATE_AVAILABLE,
      River::JOB_STATE_PENDING,
      River::JOB_STATE_RUNNING,
      River::JOB_STATE_SCHEDULED
    ]
    unique = River::UniqueOpts.new(by_queue: true, by_state: states)
    insert_job(1, unique_opts: unique)
    retryable = insert_job(2, scheduled_at: now - 1, state: River::JOB_STATE_RETRYABLE, unique_opts: unique)

    expect(driver.job_schedule(now: now)).to eq(1)
    discarded = driver.job_get_by_id(retryable.id)

    expect(discarded).to have_attributes(
      finalized_at: be_within(0.001).of(now),
      state: River::JOB_STATE_DISCARDED
    )
    expect(discarded.metadata.to_h).to include("unique_key_conflict" => "scheduler_discarded")
  end

  it "rescues a stuck job for retry" do
    inserted = insert_job(1, scheduled_at: now - 120)
    running = driver.job_get_available(attempted_by: "worker", max: 1, now: now - 120, queue: "default").first
    retry_policy = Object.new
    retry_policy.define_singleton_method(:next_retry) { |_job, _error, now:| now + 60 }

    expect(driver.job_rescue_stuck(horizon: now - 60, now: now, retry_policy: retry_policy)).to eq(1)
    rescued = driver.job_get_by_id(running.id)

    expect(rescued).to have_attributes(
      errors: contain_exactly(have_attributes(error: "Stuck job rescued by River")),
      metadata: have_attributes(to_h: include("river:rescue_count" => 1)),
      state: River::JOB_STATE_RETRYABLE
    )
    expect(inserted.id).to eq(running.id)
  end

  it "applies the rescue limit after filtering out healthy running jobs" do
    healthy = insert_job(1, scheduled_at: now - 1)
    driver.job_get_available(attempted_by: "worker", max: 1, now: now, queue: "default")
    stuck = insert_job(2, scheduled_at: now - 120)
    driver.job_get_available(attempted_by: "worker", max: 1, now: now - 120, queue: "default")

    expect(driver.job_rescue_stuck(horizon: now - 60, max: 1, now: now, retry_policy: River::DefaultClientRetryPolicy.new)).to eq(1)
    expect(client.job_get(stuck.id).state).to eq(River::JOB_STATE_RETRYABLE)
    expect(client.job_get(healthy.id).state).to eq(River::JOB_STATE_RUNNING)
  end

  it "discards a stuck job that exhausted its attempts" do
    inserted = insert_job(1, max_attempts: 1, scheduled_at: now - 120)
    running = driver.job_get_available(attempted_by: "worker", max: 1, now: now - 120, queue: "default").first

    driver.job_rescue_stuck(horizon: now - 60, now: now, retry_policy: River::DefaultClientRetryPolicy.new)

    expect(driver.job_get_by_id(inserted.id)).to have_attributes(
      attempt: running.attempt,
      finalized_at: be_within(0.001).of(now),
      state: River::JOB_STATE_DISCARDED
    )
  end

  it "cancels a stuck job with a pending cancellation request" do
    inserted = insert_job(1, scheduled_at: now - 120)
    running = driver.job_get_available(attempted_by: "worker", max: 1, now: now - 120, queue: "default").first
    driver.job_cancel(running.id, now: now - 100)

    driver.job_rescue_stuck(horizon: now - 60, now: now, retry_policy: River::DefaultClientRetryPolicy.new)

    expect(driver.job_get_by_id(inserted.id)).to have_attributes(
      finalized_at: be_within(0.001).of(now),
      state: River::JOB_STATE_CANCELLED
    )
  end

  it "ignores running jobs newer than the rescue horizon" do
    inserted = insert_job(1, scheduled_at: now - 10)
    driver.job_get_available(attempted_by: "worker", max: 1, now: now - 10, queue: "default")

    expect(driver.job_rescue_stuck(
      horizon: now - 60,
      now: now,
      retry_policy: River::DefaultClientRetryPolicy.new
    )).to eq(0)
    expect(driver.job_get_by_id(inserted.id)).to have_attributes(state: River::JOB_STATE_RUNNING)
  end

  it "rescues only attempts strictly before the horizon at millisecond precision" do
    horizon = now - 60 + Rational(123, 1_000)
    jobs = [-1, 0, 1].map do |milliseconds|
      row = insert_job(1, scheduled_at: now - 120)
      driver.job_claim(id: row.id, attempted_by: "worker", now: horizon + Rational(milliseconds, 1_000))
    end

    expect(driver.job_rescue_stuck(horizon: horizon, now: now, retry_policy: River::DefaultClientRetryPolicy.new)).to eq(1)
    expect(driver.job_get_by_id(jobs.first.id).state).to eq("retryable")
    jobs.drop(1).each do |job|
      expect(driver.job_get_by_id(job.id)).to have_attributes(state: "running", attempted_at: job.attempted_at, errors: job.errors, metadata: job.metadata)
    end
  end

  it "deletes only finalized jobs older than their state retention" do
    old_cancelled = insert_job(1)
    old_completed = insert_job(2)
    recent_cancelled = insert_job(3)
    client.job_update(old_cancelled.id, River::JobUpdateParams.new(finalized_at: now - 120, state: River::JOB_STATE_CANCELLED))
    client.job_update(old_completed.id, River::JobUpdateParams.new(finalized_at: now - 120, state: River::JOB_STATE_COMPLETED))
    client.job_update(recent_cancelled.id, River::JobUpdateParams.new(finalized_at: now - 10, state: River::JOB_STATE_CANCELLED))

    deleted = driver.job_delete_finalized(
      now: now,
      retention: {River::JOB_STATE_CANCELLED => 60, River::JOB_STATE_COMPLETED => nil}
    )

    expect(deleted).to eq(1)
    expect(driver.job_get_by_id(old_cancelled.id)).to be_nil
    expect(driver.job_get_by_id(old_completed.id)).not_to be_nil
    expect(driver.job_get_by_id(recent_cancelled.id)).not_to be_nil
  end

  it "honors the finalized cleanup limit" do
    jobs = 3.times.map do |index|
      insert_job(index).tap do |job|
        client.job_update(job.id, River::JobUpdateParams.new(finalized_at: now - 120, state: River::JOB_STATE_COMPLETED))
      end
    end

    expect(driver.job_delete_finalized(max: 2, now: now, retention: {River::JOB_STATE_COMPLETED => 60})).to eq(2)
    expect(jobs.count { |job| driver.job_get_by_id(job.id) }).to eq(1)
  end

  it "does nothing when all finalized retention policies are disabled" do
    expect(driver.job_delete_finalized(now: now, retention: {River::JOB_STATE_COMPLETED => nil})).to eq(0)
  end

  it "returns no jobs when bulk deletion matches nothing" do
    expect(driver.job_delete_many(River::JobListParams.new(ids: [-1]))).to eq([])
  end

  it "rejects update fields outside JobUpdateParams" do
    params = Object.new
    params.define_singleton_method(:each) { [[:unknown, true]].each }

    expect { driver.job_update(-1, params) }.to raise_error(ArgumentError, /unknown update field: unknown/)
  end

  it "replaces nested metadata values and preserves null values" do
    job = insert_job(1, metadata: {"nested" => {"old" => true}, "nullable" => 2})
    updates = {"nested" => {"new" => true}, "nullable" => nil}

    expected = job.metadata.to_h.merge(updates)

    expect(driver.job_metadata_merge(job.id, updates).metadata.to_h).to eq(expected)
    expect(driver.job_metadata_merge(job.id, {}).metadata.to_h).to eq(expected)
  end

  it "returns nil when merging metadata into a missing job" do
    expect(driver.job_metadata_merge(-1, {"missing" => true})).to be_nil
  end

  it "supports the unfiltered internal job list" do
    inserted = [insert_job(1), insert_job(2)]

    expect(driver.job_list(:all).map(&:id)).to eq(inserted.map(&:id))
  end

  it "filters and sorts jobs independently" do
    first = insert_job(1, metadata: {"tenant" => "a"}, priority: 2, queue: "one", scheduled_at: now - 30, tags: %w[red shared])
    second = insert_job(2, metadata: {"tenant" => "b"}, priority: 3, queue: "two", scheduled_at: now - 20, tags: %w[blue shared])
    third = insert_job(3, metadata: {"tenant" => "a"}, priority: 2, queue: "one", scheduled_at: now - 10, tags: %w[red])

    expect(driver.job_list(River::JobListParams.new(tags_all: %w[red shared])).map(&:id)).to eq([first.id])
    expect(driver.job_list(River::JobListParams.new(tags_any: %w[missing blue])).map(&:id)).to eq([second.id])
    expect(driver.job_list(River::JobListParams.new(metadata: {tenant: "a"}, priorities: [2])).map(&:id)).to eq([first.id, third.id])
    expect(driver.job_list(River::JobListParams.new(queues: ["one"], sort_by: :scheduled_at, sort_order: :desc)).map(&:id))
      .to eq([third.id, first.id])
  end
end

RSpec.shared_examples "driver queue and leadership state" do
  let(:now) { Time.utc(2026, 1, 2, 3, 4, 5) }

  it "gets, lists, and updates queues without changing unrelated fields" do
    driver.queue_upsert("zeta", now: now)
    driver.queue_upsert("alpha", now: now)

    expect(driver.queue_get("missing")).to be_nil
    expect(driver.queue_list(max: 1)).to contain_exactly(have_attributes(name: "alpha"))
    expect(driver.queue_update("alpha", metadata: {"team" => "ruby"}, now: now + 10)).to have_attributes(
      created_at: be_within(0.001).of(now), metadata: {"team" => "ruby"}, name: "alpha",
      paused_at: nil, updated_at: be_within(0.001).of(now + 10)
    )
    expect(driver.queue_update("missing", metadata: {})).to be_nil
  end

  it "pauses and resumes only the named queue" do
    driver.queue_upsert("one", now: now)
    driver.queue_upsert("two", now: now)
    driver.queue_pause("one", now: now + 10)

    expect(driver.queue_get("two")).to have_attributes(paused_at: nil)
    driver.queue_resume("one", now: now + 20)
    driver.queue_resume("one", now: now + 30)

    expect(driver.queue_get("one")).to have_attributes(paused_at: nil, updated_at: be_within(0.001).of(now + 20))
  end

  it "does not release another client's leadership" do
    driver.leader_acquire("one", now: now)
    driver.leader_release("two")

    expect(driver.leader_acquire("two", now: now)).to be false
    expect(driver.leader_renew("one", now: now)).to be true
  end

  it "upserts a queue without replacing its metadata" do
    original = driver.queue_upsert("work", metadata: {"team" => "ruby"}, now: now)
    refreshed = driver.queue_upsert("work", metadata: {"team" => "other"}, now: now + 10)

    expect(original.metadata).to eq("team" => "ruby")
    expect(refreshed).to have_attributes(
      created_at: be_within(0.001).of(now),
      metadata: {"team" => "ruby"},
      updated_at: be_within(0.001).of(now + 10)
    )
  end

  it "keeps the original pause timestamp across repeated pauses" do
    driver.queue_upsert("work", now: now)
    driver.queue_pause("work", now: now + 10)
    driver.queue_pause("work", now: now + 20)

    expect(driver.queue_get("work")).to have_attributes(
      paused_at: be_within(0.001).of(now + 10),
      updated_at: be_within(0.001).of(now + 10)
    )
  end

  it "pauses and resumes every queue with the wildcard" do
    driver.queue_upsert("one", now: now)
    driver.queue_upsert("two", now: now)

    driver.queue_pause("*", now: now + 10)

    expect(driver.queue_list).to all(have_attributes(paused_at: be_a(Time)))
    driver.queue_resume("*", now: now + 20)

    expect(driver.queue_list).to all(have_attributes(paused_at: nil, updated_at: be_within(0.001).of(now + 20)))
  end

  it "elects only one live leader" do
    expect(driver.leader_acquire("one", now: now, ttl: 30)).to be true
    expect(driver.leader_acquire("two", now: now, ttl: 30)).to be false
  end

  it "allows a new leader after expiration" do
    driver.leader_acquire("one", now: now, ttl: 10)

    expect(driver.leader_acquire("two", now: now + 11, ttl: 30)).to be true
  end

  it "renews only the current unexpired leader" do
    driver.leader_acquire("one", now: now, ttl: 10)

    expect(driver.leader_renew("one", now: now + 5, ttl: 30)).to be true
    expect(driver.leader_renew("two", now: now + 5, ttl: 30)).to be false
    expect(driver.leader_renew("one", now: now + 40, ttl: 30)).to be false
  end

  it "releases leadership" do
    driver.leader_acquire("one", now: now)
    driver.leader_release("one")

    expect(driver.leader_acquire("two", now: now)).to be true
  end
end
