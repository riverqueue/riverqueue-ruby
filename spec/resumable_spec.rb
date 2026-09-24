# frozen_string_literal: true

require "spec_helper"

RSpec.describe River::ResumableState do
  it "starts at the beginning without persisted progress" do
    state = described_class.new({})

    expect(state).to have_attributes(had_cursors: false, resume_matched: true, resume_step: nil)
    expect(state.cursors).to eq({})
  end

  it "loads persisted step and cursor progress defensively" do
    metadata = {
      River::RESUMABLE_STEP_METADATA_KEY => "items",
      River::RESUMABLE_CURSOR_METADATA_KEY => {"items" => 4}
    }
    state = described_class.new(metadata)
    state.cursors["items"] = 5

    expect(state).to have_attributes(had_cursors: true, resume_matched: false, resume_step: "items")
    expect(metadata.fetch(River::RESUMABLE_CURSOR_METADATA_KEY)).to eq("items" => 4)
  end

  it "rejects duplicate step names" do
    state = described_class.new({})

    expect(state.register("same")).to be_truthy
    expect(state.register("same")).to be false
    expect(state.error).to be_a(River::Error).and have_attributes(message: 'duplicate resumable step name "same"')
  end
end

RSpec.describe "resumable job execution" do
  def build_row(metadata: {}, state: River::JOB_STATE_RUNNING)
    River::JobRow.new(
      id: 123,
      args: {},
      attempt: 1,
      created_at: Time.now.utc,
      kind: "resumable",
      max_attempts: 3,
      metadata: metadata,
      priority: 1,
      queue: "default",
      scheduled_at: Time.now.utc,
      state: state
    )
  end

  def build_job(row: build_row, driver: Object.new)
    River::Job.new(Struct.new(:driver).new(driver), row)
  end

  it "runs named steps in order and returns their values" do
    job = build_job
    calls = []

    expect(job.resumable_step("first") {
      calls << "first"
      1
    }).to eq(1)
    expect(job.resumable_step("second") {
      calls << "second"
      2
    }).to eq(2)
    expect { job.__finish_resumable_work! }.not_to raise_error
    expect(calls).to eq(%w[first second])
  end

  it "supplies a default cursor and normalizes saved cursors through JSON" do
    job = build_job
    received = nil

    job.resumable_step_cursor :items, default: {start: 1} do |cursor|
      received = cursor
      job.resumable_set_cursor(symbol_key: 2)
      raise "retry"
    end

    job.__capture_resumable_metadata!

    expect(received).to eq(start: 1)
    expect(job.metadata_updates).to eq(
      River::RESUMABLE_CURSOR_METADATA_KEY => {"items" => {"symbol_key" => 2}}
    )
  end

  it "skips completed steps when resuming" do
    job = build_job(row: build_row(metadata: {River::RESUMABLE_STEP_METADATA_KEY => "download"}))
    calls = []

    job.resumable_step(:prepare) { calls << "prepare" }
    job.resumable_step(:download) { calls << "download" }
    job.resumable_step(:process) { calls << "process" }
    job.__finish_resumable_work!

    expect(calls).to eq(["process"])
  end

  it "resumes a cursor step from its persisted cursor" do
    metadata = {
      River::RESUMABLE_STEP_METADATA_KEY => "items",
      River::RESUMABLE_CURSOR_METADATA_KEY => {"items" => 7}
    }
    job = build_job(row: build_row(metadata: metadata))
    received = nil

    job.resumable_step("prepare") { raise "must be skipped" }
    job.resumable_step_cursor(:items, default: 0) { |cursor| received = cursor }
    job.__finish_resumable_work!

    expect(received).to eq(7)
  end

  it "removes a completed persisted cursor on the next failed attempt" do
    metadata = {
      River::RESUMABLE_STEP_METADATA_KEY => "items",
      River::RESUMABLE_CURSOR_METADATA_KEY => {"items" => 7}
    }
    job = build_job(row: build_row(metadata: metadata))
    job.resumable_step_cursor("items") { |_cursor| }
    job.__capture_resumable_metadata!

    expect(job.metadata_updates).to include(
      River::RESUMABLE_STEP_METADATA_KEY => "items",
      River::RESUMABLE_CURSOR_METADATA_KEY => nil
    )
  end

  it "captures a completed non-cursor step without cursor metadata" do
    job = build_job
    job.resumable_step(:done) {}

    job.__capture_resumable_metadata!

    expect(job.metadata_updates).to eq(River::RESUMABLE_STEP_METADATA_KEY => "done")
  end

  it "defers a step error until work finishes" do
    job = build_job
    result = job.resumable_step("fails") { raise "step failed" }

    expect(result).to be_nil
    expect { job.__finish_resumable_work! }.to raise_error(RuntimeError, "step failed")
  end

  it "does not run later steps after a step error" do
    job = build_job
    later_ran = false
    job.resumable_step("fails") { raise "step failed" }
    job.resumable_step("later") { later_ran = true }

    expect(later_ran).to be false
  end

  it "reports a persisted resume step missing from the worker" do
    job = build_job(row: build_row(metadata: {River::RESUMABLE_STEP_METADATA_KEY => "removed"}))
    job.resumable_step("current") {}

    expect { job.__finish_resumable_work! }
      .to raise_error(River::Error, 'resumable step "removed" not found in worker')
  end

  it "reports duplicate step names after work finishes" do
    job = build_job
    job.resumable_step("same") {}
    job.resumable_step(:same) {}

    expect { job.__finish_resumable_work! }
      .to raise_error(River::Error, 'duplicate resumable step name "same"')
  end

  it "rejects an empty step name" do
    expect { build_job.resumable_step("") {} }
      .to raise_error(ArgumentError, "resumable step name must be non-empty")
  end

  it "rejects setting a cursor outside a step" do
    expect { build_job.resumable_set_cursor(1) }
      .to raise_error(River::Error, "resumable cursor can only be set inside a resumable step")
  end

  it "rejects persisting outside a step" do
    expect { build_job.resumable_checkpoint }
      .to raise_error(River::Error, "resumable step can only be persisted inside a resumable step")
  end

  it "requires a running job for an immediate checkpoint" do
    job = build_job(row: build_row(state: River::JOB_STATE_AVAILABLE))
    captured = nil
    job.resumable_step("inside") do
      captured = begin
        job.resumable_checkpoint
      rescue => error
        error
      end
    end

    expect(captured).to be_a(River::Error).and have_attributes(message: "job must be running")
  end

  it "persists the current step and optional cursor immediately" do
    row = build_row
    received = nil
    driver = Object.new
    driver.define_singleton_method(:job_metadata_merge) do |id, updates|
      received = [id, updates]
      row.dup.tap { |updated| updated.metadata = row.metadata.merge(updates) }
    end

    job = build_job(driver: driver, row: row)

    job.resumable_step_cursor("items") { job.resumable_checkpoint(cursor: {last_id: 42}) }

    expect(received).to eq([
      123,
      {
        River::RESUMABLE_STEP_METADATA_KEY => "items",
        River::RESUMABLE_CURSOR_METADATA_KEY => {"items" => {"last_id" => 42}}
      }
    ])
    expect(job.metadata).to include(River::RESUMABLE_STEP_METADATA_KEY => "items")
  end

  it "raises when the job disappears during an immediate checkpoint" do
    driver = Object.new
    driver.define_singleton_method(:job_metadata_merge) { |_id, _updates| nil }
    job = build_job(driver: driver)
    captured = nil
    job.resumable_step("inside") do
      captured = begin
        job.resumable_checkpoint
      rescue => error
        error
      end
    end

    expect(captured).to be_a(River::NotFoundError).and have_attributes(message: "job not found: 123")
  end
end
