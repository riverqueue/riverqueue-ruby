# frozen_string_literal: true

require "spec_helper"

RSpec.describe River::PeriodicJob do
  it "uses an object schedule implementing next" do
    now = Time.utc(2026, 1, 1)
    job = described_class.new(constructor: -> {}, schedule: River::PeriodicInterval.new(60))

    expect(job.next_at(now)).to eq(now + 60)
  end

  it "uses a callable schedule" do
    now = Time.utc(2026, 1, 1)
    job = described_class.new(constructor: -> {}, schedule: ->(time) { time + 30 })

    expect(job.next_at(now)).to eq(now + 30)
  end

  it "retains registration attributes" do
    constructor = -> { :args }
    job = described_class.new(id: "cleanup", constructor: constructor, run_on_start: true, schedule: ->(time) { time })

    expect(job).to have_attributes(id: "cleanup", constructor: constructor, run_on_start: true)
  end

  it "normalizes symbolic IDs to strings" do
    job = described_class.new(id: :cleanup, constructor: -> {}, schedule: ->(time) { time })

    expect(job.id).to eq("cleanup")
  end
end

RSpec.describe River::PeriodicInterval do
  it "coerces seconds and advances a time" do
    now = Time.utc(2026, 1, 1)

    expect(described_class.new("1.5").next(now)).to eq(now + 1.5)
  end

  [0, -1].each do |seconds|
    it "rejects interval #{seconds}" do
      expect { described_class.new(seconds) }.to raise_error(ArgumentError, "period must be greater than zero")
    end
  end

  it "rejects a nonnumeric interval" do
    expect { described_class.new("daily") }.to raise_error(ArgumentError)
  end
end

RSpec.describe River::PeriodicJobBundle do
  let(:wake) { proc {} }
  let(:schedule) { ->(time) { time + 60 } }

  def periodic(id: nil, run_on_start: false, schedule: ->(time) { time + 60 })
    River::PeriodicJob.new(id: id, constructor: -> {}, run_on_start: run_on_start, schedule: schedule)
  end

  it "assigns increasing handles and wakes for every addition" do
    wake_count = 0
    jobs = described_class.new([], wake: -> { wake_count += 1 })

    expect(jobs.add(periodic(id: "one"))).to eq(1)
    expect(jobs.add_many([periodic(id: "two"), periodic])).to eq([2, 3])
    expect(wake_count).to eq(3)
  end

  it "rejects duplicate non-nil IDs" do
    jobs = described_class.new([periodic(id: "same")], wake: wake)

    expect { jobs.add(periodic(id: "same")) }
      .to raise_error(ArgumentError, "periodic job ID is already registered: same")
  end

  it "allows multiple anonymous registrations" do
    jobs = described_class.new([], wake: wake)

    expect { jobs.add_many([periodic, periodic]) }.not_to raise_error
  end

  it "treats string and symbol IDs as the same registration" do
    jobs = described_class.new([periodic(id: :cleanup)], wake: wake)

    expect { jobs.add(periodic(id: "cleanup")) }
      .to raise_error(ArgumentError, "periodic job ID is already registered: cleanup")
    expect(jobs.remove_by_id(:cleanup)).to be true
    expect(jobs.remove_by_id("cleanup")).to be false
    expect(jobs.remove_by_id(nil)).to be false
  end

  it "makes run-on-start jobs immediately due" do
    job = periodic(id: "startup", run_on_start: true)
    jobs = described_class.new([job], wake: wake)

    expect(jobs.due(Time.now.utc + 1)).to eq([job])
  end

  it "does not return future jobs" do
    jobs = described_class.new([periodic], wake: wake)

    expect(jobs.due(Time.now.utc)).to be_empty
  end

  it "reschedules a due job from the supplied time" do
    calls = []
    schedule = ->(time) {
      calls << time
      time + 60
    }
    job = periodic(run_on_start: true, schedule: schedule)
    jobs = described_class.new([job], wake: wake)
    due_at = Time.now.utc + 1

    expect(jobs.due(due_at)).to eq([job])
    expect(jobs.due(due_at + 30)).to be_empty
    expect(calls.last).to eq(due_at)
  end

  it "removes a registration by handle" do
    jobs = described_class.new([], wake: wake)
    handle = jobs.add(periodic(run_on_start: true))

    expect(jobs.remove(handle)).to be_a(Hash)
    expect(jobs.remove(handle)).to be_nil
    expect(jobs.due(Time.now.utc + 1)).to be_empty
  end

  it "removes a registration by ID" do
    jobs = described_class.new([periodic(id: "remove", run_on_start: true)], wake: wake)

    expect(jobs.remove_by_id("remove")).to be true
    expect(jobs.remove_by_id("remove")).to be false
  end

  it "clears all registrations" do
    jobs = described_class.new([periodic(run_on_start: true), periodic(run_on_start: true)], wake: wake)
    jobs.clear

    expect(jobs.due(Time.now.utc + 1)).to be_empty
  end
end
