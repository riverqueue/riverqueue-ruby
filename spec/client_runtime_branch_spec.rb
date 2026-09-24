# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe River::ClientRuntime do
  def row(id: 1, metadata: {}, max_attempts: 1)
    River::JobRow.new(
      id: id,
      args: {},
      attempt: 1,
      created_at: Time.now.utc,
      kind: "branch_worker",
      max_attempts: max_attempts,
      metadata: metadata,
      priority: 1,
      queue: "branch",
      scheduled_at: Time.now.utc,
      state: River::JOB_STATE_RUNNING
    )
  end

  def config(worker: Object.new, queues: {})
    River::Config.new(
      id: "branch-runtime",
      logger: Logger.new(StringIO.new),
      queues: queues,
      workers: River::Workers.new.add("branch_worker", worker)
    )
  end

  def runtime(driver: Object.new, worker: Object.new, queues: {})
    described_class.new(Object.new, driver, config(queues: queues, worker: worker))
  end

  def execute(runtime, value)
    runtime.instance_variable_set(
      :@running,
      value.id => {queue: value.queue, thread: Thread.current, working: false}
    )
    runtime.send(:execute, value)
  end

  it "detects dead runtime threads, excluding intentionally removed or stopped producers" do
    value = runtime
    thread = Object.new
    alive = true
    thread.define_singleton_method(:alive?) { alive }
    value.instance_variable_set(:@producer_threads, {"branch" => thread})
    expect(value.healthy?).to be true
    alive = false
    expect(value.healthy?).to be false
    value.instance_variable_set(:@removed_queues, {"branch" => true})
    expect(value.healthy?).to be true
    value.instance_variable_set(:@maintenance_thread, thread)
    expect(value.healthy?).to be false
    alive = true
    expect(value.healthy?).to be true
    alive = false
    value.instance_variable_set(:@stop_requested, true)
    expect(value.healthy?).to be true
  end

  it "interrupts only working attempts through the client runner extension" do
    value = runtime
    errors = []
    thread = Object.new
    thread.define_singleton_method(:raise) { |error| errors << error }
    value.instance_variable_set(:@running, {1 => {thread: thread, working: true}, 2 => {thread: thread, working: false}})
    client = River::Client.new(Object.new)
    client.instance_variable_set(:@runtime, value)
    client.__interrupt_workers
    expect(errors).to eq([River::ClientRuntime::Interrupted])
    expect(client.__runtime_healthy?).to be true
  end

  [true, false].each do |retry_error|
    it "honors worker retry? returning #{retry_error}" do
      worker = Object.new
      worker.define_singleton_method(:retry?) { |_job, _error| retry_error }
      worker.define_singleton_method(:next_retry) { |_job, _error| Time.now.utc + 60 }
      updates = []
      driver = Object.new
      driver.define_singleton_method(:job_set_state_if_running) { |**params|
        updates << params
        nil
      }

      value = row(max_attempts: 25)
      runtime(driver: driver, worker: worker).send(:finish_failed, value,
        River::Job.new(Object.new, value), RuntimeError.new("failed"), Time.now.utc, worker: worker)

      expect(updates.last[:state]).to eq(retry_error ? River::JOB_STATE_RETRYABLE : River::JOB_STATE_DISCARDED)
    end
  end

  it "does not publish completion when an externally claimed job lost its running state" do
    driver = Object.new
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }

    expect(runtime(driver: driver).finish_claimed(row)).to be_nil
  end

  it "starts a producer and maintenance when adding a queue to a running client" do
    value = runtime
    calls = []
    value.instance_variable_set(:@started, true)
    value.instance_variable_set(:@stop_requested, false)
    value.define_singleton_method(:start_producer) { |name, queue_config| calls << [:producer, name, queue_config] }
    value.define_singleton_method(:start_maintenance) { calls << [:maintenance] }

    queue_config = value.queue_add("dynamic", 2)

    expect(calls).to eq([[:producer, "dynamic", queue_config], [:maintenance]])
  end

  it "joins only work belonging to a queue as it is removed" do
    value = runtime(queues: {keep: 1, remove: 1})
    joins = []
    producer = Object.new
    producer.define_singleton_method(:join) { joins << :producer }
    removed_worker = Object.new
    removed_worker.define_singleton_method(:join) { joins << :removed_worker }
    kept_worker = Object.new
    kept_worker.define_singleton_method(:join) { joins << :kept_worker }
    value.instance_variable_set(:@producer_threads, {"remove" => producer})
    value.instance_variable_set(
      :@running,
      {
        1 => {queue: "remove", thread: removed_worker, working: true},
        2 => {queue: "keep", thread: kept_worker, working: true}
      }
    )

    expect(value.queue_remove("remove")).to be true
    expect(joins).to eq([:producer, :removed_worker])
  end

  it "handles a temporarily failing producer and retries until stopped" do
    driver = Object.new
    driver.define_singleton_method(:queue_get) { |_queue| raise "temporary producer failure" }
    value = runtime(driver: driver)
    checks = 0
    value.define_singleton_method(:queue_stopping?) do |_queue|
      checks += 1
      checks >= 3
    end

    value.define_singleton_method(:wait) { |_duration| }

    expect { value.send(:producer_loop, "branch", River::QueueConfig.new(max_workers: 1)) }.not_to raise_error
    expect(checks).to eq(3)
  end

  it "does not retry a failed producer after its queue stops" do
    driver = Object.new
    driver.define_singleton_method(:queue_get) { |_queue| raise "terminal producer failure" }
    value = runtime(driver: driver)
    checks = 0
    value.define_singleton_method(:queue_stopping?) do |_queue|
      checks += 1
      checks >= 2
    end

    value.define_singleton_method(:wait) { |_duration| }

    expect { value.send(:producer_loop, "branch", River::QueueConfig.new(max_workers: 1)) }.not_to raise_error
    expect(checks).to eq(2)
  end

  it "can poll a queue before its persisted queue row is visible" do
    driver = Object.new
    driver.define_singleton_method(:queue_get) { |_queue| nil }
    driver.define_singleton_method(:job_get_available) { |**| [] }
    value = runtime(driver: driver)
    checks = 0
    value.define_singleton_method(:queue_stopping?) do |_queue|
      checks += 1
      checks >= 2
    end

    value.define_singleton_method(:wait) { |_duration| }

    value.send(:producer_loop, "branch", River::QueueConfig.new(max_workers: 1))

    expect(checks).to eq(2)
  end

  it "skips maintenance work while another client holds leadership" do
    driver = Object.new
    driver.define_singleton_method(:leader_acquire) { |_id, **| false }
    value = runtime(driver: driver)
    checks = 0
    value.define_singleton_method(:stopping?) do
      checks += 1
      checks >= 2
    end

    value.define_singleton_method(:wait) { |_duration| }

    value.send(:maintenance_loop)

    expect(checks).to eq(2)
  end

  it "retries a temporarily failing maintenance loop" do
    driver = Object.new
    driver.define_singleton_method(:leader_acquire) { |_id, **| raise "temporary maintenance failure" }
    value = runtime(driver: driver)
    checks = 0
    value.define_singleton_method(:stopping?) do
      checks += 1
      checks >= 3
    end

    value.define_singleton_method(:wait) { |_duration| }

    expect { value.send(:maintenance_loop) }.not_to raise_error
    expect(checks).to eq(3)
  end

  it "does not retry failed maintenance after stop begins" do
    driver = Object.new
    driver.define_singleton_method(:leader_acquire) { |_id, **| raise "terminal maintenance failure" }
    value = runtime(driver: driver)
    checks = 0
    value.define_singleton_method(:stopping?) do
      checks += 1
      checks >= 2
    end

    value.define_singleton_method(:wait) { |_duration| }

    expect { value.send(:maintenance_loop) }.not_to raise_error
    expect(checks).to eq(2)
  end

  it "logs and isolates a periodic constructor failure" do
    output = StringIO.new
    periodic = River::PeriodicJob.new(
      constructor: -> { raise "periodic failed" },
      run_on_start: true,
      schedule: River::PeriodicInterval.new(60)
    )
    runtime_config = config.with(logger: Logger.new(output), periodic_jobs: [periodic])
    value = described_class.new(Object.new, Object.new, runtime_config)

    expect { value.send(:run_periodic, Time.now.utc + 1) }.not_to raise_error
    expect(output.string).to include("River periodic job failed to insert", "periodic failed")
  end

  it "handles a job deleted after successful work" do
    worker = Class.new {
      def work(_job)
      end
    }

    driver = Object.new
    driver.define_singleton_method(:job_complete) { |**| nil }
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }
    value = runtime(driver: driver, worker: worker)

    expect { execute(value, row) }.not_to raise_error
  end

  it "uses the completion operation without fetching a full job" do
    worker = Class.new {
      def work(_job)
      end
    }

    driver = Object.new
    checked = []
    driver.define_singleton_method(:job_complete) { |**params|
      checked << params[:id]
      nil
    }
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }
    value = runtime(driver: driver, worker: worker)

    expect(execute(value, row)).to eq([:completed, nil])
    expect(checked).to eq([1])
  end

  it "turns a post-work cancellation marker into a cancelled attempt" do
    worker = Class.new {
      def work(_job)
      end
    }

    driver = Object.new
    driver.define_singleton_method(:job_complete) { |**| :cancelled }
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }
    value = runtime(driver: driver, worker: worker)

    expect(execute(value, row).first).to eq(:cancelled)
  end

  it "handles an interrupt after another actor has already transitioned the job" do
    worker = Class.new { def work(_job) = raise(River::ClientRuntime::Interrupted) }
    driver = Object.new
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }
    value = runtime(driver: driver, worker: worker)

    expect { execute(value, row) }.not_to raise_error
  end

  it "handles a snooze after another actor has already transitioned the job" do
    worker = Class.new { def work(_job) = raise(River.job_snooze(10)) }
    driver = Object.new
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }
    value = runtime(driver: driver, worker: worker)

    expect { execute(value, row) }.not_to raise_error
  end

  it "handles a failure after another actor has already transitioned the job" do
    worker = Class.new { def work(_job) = raise("failed") }
    driver = Object.new
    driver.define_singleton_method(:job_set_state_if_running) { |**| nil }
    value = runtime(driver: driver, worker: worker)

    expect { execute(value, row) }.not_to raise_error
  end

  it "checks cancellation in one batch, excluding inactive work and other queues" do
    raised = []
    fake_thread = Object.new
    fake_thread.define_singleton_method(:raise) { |error| raised << error }
    checked = []
    driver = Object.new
    driver.define_singleton_method(:job_get_cancelled_ids) { |ids|
      checked << ids
      [3]
    }
    value = runtime(driver: driver)
    value.instance_variable_set(
      :@running,
      {
        1 => {queue: "other", thread: fake_thread, working: true},
        2 => {queue: "branch", thread: fake_thread, working: false},
        3 => {queue: "branch", thread: fake_thread, working: true}
      }
    )

    value.send(:check_remote_cancellations, "branch")

    expect(raised).to eq([River::JobCancelError])
    expect(checked).to eq([[3]])
  end

  it "interrupts work that begins after stop was requested" do
    value = runtime
    value.instance_variable_set(:@stop_requested, true)
    value.instance_variable_set(
      :@running,
      1 => {queue: "branch", thread: Thread.current, working: false}
    )

    expect { value.send(:begin_work, 1) }.to raise_error(River::ClientRuntime::Interrupted)
  end

  it "tolerates work disappearing before its working flag is cleared" do
    value = runtime

    expect(value.send(:finish_work, 999)).to be_nil
  end

  it "does not start a second live maintenance thread" do
    value = runtime
    release = Queue.new
    thread = Thread.new { release.pop }
    value.instance_variable_set(:@maintenance_thread, thread)
    value.instance_variable_set(:@threads, [thread])

    expect(value.send(:start_maintenance)).to be_nil
    expect(value.instance_variable_get(:@threads)).to eq([thread])
  ensure
    release << true
    thread&.join
  end

  it "does not enter a condition wait once stop is requested" do
    value = runtime
    value.instance_variable_set(:@stop_requested, true)

    expect(value.send(:wait, 0)).to be_nil
  end
end
