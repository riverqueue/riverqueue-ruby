# frozen_string_literal: true

require "spec_helper"
require_relative "../driver/riverqueue-sequel/spec/spec_helper"

class InsertionFeatureArgs
  attr_accessor :insert_opts

  def initialize(kind: "insertion_feature", payload: {"value" => 1}, insert_opts: nil)
    @insert_opts = insert_opts
    @kind = kind
    @payload = payload
  end

  attr_reader :kind

  def to_json = JSON.dump(@payload)
end

RSpec.describe "River insertion features" do
  around(:each) { |example| available_test_transaction(&example) }

  let(:driver) { River::Driver::Sequel.new(available_test_database) }

  def build_client(**config)
    River::Client.new(driver, config: River::Config.new(**config))
  end

  it "merges argument metadata with call-site metadata taking precedence" do
    args = InsertionFeatureArgs.new(insert_opts: River::InsertOpts.new(metadata: {"one" => 1, "shared" => "args"}))
    result = build_client.insert(
      args,
      insert_opts: River::InsertOpts.new(metadata: {"shared" => "call", "two" => 2})
    )

    expect(result.job.metadata.except("river:unique_nonce")).to eq(
      "one" => 1,
      "shared" => "call",
      "two" => 2
    )
  end

  it "supports an explicit initial pending state" do
    result = build_client.insert(
      InsertionFeatureArgs.new,
      insert_opts: River::InsertOpts.new(state: River::JOB_STATE_PENDING)
    )

    expect(result.job).to have_attributes(state: River::JOB_STATE_PENDING)
  end

  it "honors an explicit available state for a future scheduled time" do
    scheduled_at = Time.now.utc + 60
    result = build_client.insert(
      InsertionFeatureArgs.new,
      insert_opts: River::InsertOpts.new(scheduled_at: scheduled_at, state: River::JOB_STATE_AVAILABLE)
    )

    expect(result.job).to have_attributes(
      scheduled_at: be_within(0.001).of(scheduled_at),
      state: River::JOB_STATE_AVAILABLE
    )
  end

  it "accepts nil argument-level insertion options" do
    result = build_client.insert(InsertionFeatureArgs.new(insert_opts: nil))

    expect(result.job).to have_attributes(max_attempts: River::MAX_ATTEMPTS_DEFAULT, queue: River::QUEUE_DEFAULT)
  end

  it "runs plugin insert callbacks in forward and reverse order" do
    calls = []
    first = Object.new
    first.define_singleton_method(:insert_begin) { |params| calls << [:first_begin, params.kind] }
    first.define_singleton_method(:insert_end) { |result| calls << [:first_end, result.job.kind] }
    second = Object.new
    second.define_singleton_method(:insert_begin) { |params| calls << [:second_begin, params.kind] }
    second.define_singleton_method(:insert_end) { |result| calls << [:second_end, result.job.kind] }

    build_client(plugins: [first, second]).insert(InsertionFeatureArgs.new)

    expect(calls).to eq([
      [:first_begin, "insertion_feature"],
      [:second_begin, "insertion_feature"],
      [:second_end, "insertion_feature"],
      [:first_end, "insertion_feature"]
    ])
  end

  it "runs plugin insert callbacks for every job in a bulk insertion" do
    calls = []
    plugin = Object.new
    plugin.define_singleton_method(:insert_begin) { |params| calls << [:begin, params.args.to_json] }
    plugin.define_singleton_method(:insert_end) { |result| calls << [:end, result.job.args] }
    client = build_client(plugins: [plugin])

    results = client.insert_many([
      InsertionFeatureArgs.new(payload: {"value" => 1}),
      InsertionFeatureArgs.new(payload: {"value" => 2})
    ])

    expect(results.length).to eq(2)
    expect(calls.map(&:first)).to eq([:begin, :begin, :end, :end])
  end

  it "runs insertion middleware plugins outside-in around callbacks and insertion" do
    calls = []
    callback = Object.new
    callback.define_singleton_method(:insert_begin) { |_params| calls << :insert_begin }
    callback.define_singleton_method(:insert_end) { |_result| calls << :insert_end }
    first = Object.new
    first.define_singleton_method(:insert_many) do |params, operation|
      calls << [:first_before, params.length]
      results = operation.call
      calls << :first_after
      results
    end

    second = Object.new
    second.define_singleton_method(:insert_many) do |_params, operation|
      calls << :second_before
      results = operation.call
      calls << :second_after
      results
    end

    result = build_client(plugins: [first, callback, second]).insert(InsertionFeatureArgs.new)

    expect(result.job.kind).to eq("insertion_feature")
    expect(calls).to eq([
      [:first_before, 1], :second_before, :insert_begin, :insert_end,
      :second_after, :first_after
    ])
  end

  it "allows plugins that implement no insertion behavior" do
    client = build_client(plugins: [Object.new])

    result = client.insert_many([InsertionFeatureArgs.new])

    expect(result.length).to eq(1)
  end

  it "passes a bulk insertion to plugin middleware as one operation" do
    observed = []
    plugin = Object.new
    plugin.define_singleton_method(:insert_many) do |params, operation|
      observed << params.map(&:kind)
      operation.call
    end

    client = build_client(plugins: [plugin])

    results = client.insert_many([
      InsertionFeatureArgs.new(kind: "first"),
      InsertionFeatureArgs.new(kind: "second")
    ])

    expect(results.map { |result| result.job.kind }).to eq(%w[first second])
    expect(observed).to eq([%w[first second]])
  end

  it "handles an empty bulk insertion" do
    expect(build_client.insert_many([])).to eq([])
    expect(driver.job_list).to be_empty
  end

  it "treats a completed job as a duplicate with default unique states" do
    client = build_client
    opts = River::InsertOpts.new(unique_opts: River::UniqueOpts.new(by_queue: true))
    original = client.insert(InsertionFeatureArgs.new, insert_opts: opts).job
    running = driver.job_get_available(attempted_by: "worker", max: 1, queue: original.queue).first
    driver.job_set_state_if_running(id: running.id, finalized_at: Time.now.utc, state: River::JOB_STATE_COMPLETED)

    duplicate = client.insert(InsertionFeatureArgs.new, insert_opts: opts)

    expect(duplicate.unique_skipped_as_duplicated).to be true
    expect(duplicate.job.id).to eq(original.id)
  end

  it "allows a new job when its custom unique states exclude completed jobs" do
    client = build_client
    opts = River::InsertOpts.new(unique_opts: River::UniqueOpts.new(
      by_queue: true,
      by_state: [
        River::JOB_STATE_AVAILABLE,
        River::JOB_STATE_PENDING,
        River::JOB_STATE_RUNNING,
        River::JOB_STATE_SCHEDULED
      ]
    ))
    original = client.insert(InsertionFeatureArgs.new, insert_opts: opts).job
    running = driver.job_get_available(attempted_by: "worker", max: 1, queue: original.queue).first
    driver.job_set_state_if_running(id: running.id, finalized_at: Time.now.utc, state: River::JOB_STATE_COMPLETED)

    replacement = client.insert(InsertionFeatureArgs.new, insert_opts: opts)

    expect(replacement.unique_skipped_as_duplicated).to be false
    expect(replacement.job.id).not_to eq(original.id)
  end

  it "can enforce uniqueness across different kinds when kind is excluded" do
    client = build_client
    opts = River::InsertOpts.new(unique_opts: River::UniqueOpts.new(by_queue: true, exclude_kind: true))
    original = client.insert(InsertionFeatureArgs.new(kind: "first"), insert_opts: opts)
    duplicate = client.insert(InsertionFeatureArgs.new(kind: "second"), insert_opts: opts)

    expect(original.unique_skipped_as_duplicated).to be false
    expect(duplicate.unique_skipped_as_duplicated).to be true
    expect(duplicate.job.id).to eq(original.job.id)
  end

  it "allows unique jobs in adjacent time periods" do
    client = build_client
    opts = ->(scheduled_at) do
      River::InsertOpts.new(
        scheduled_at: scheduled_at,
        unique_opts: River::UniqueOpts.new(by_period: 60)
      )
    end
    first = client.insert(InsertionFeatureArgs.new, insert_opts: opts.call(Time.utc(2026, 1, 1, 0, 0, 59)))
    second = client.insert(InsertionFeatureArgs.new, insert_opts: opts.call(Time.utc(2026, 1, 1, 0, 1, 0)))

    expect(first.unique_skipped_as_duplicated).to be false
    expect(second.unique_skipped_as_duplicated).to be false
    expect(second.job.id).not_to eq(first.job.id)
  end
end
