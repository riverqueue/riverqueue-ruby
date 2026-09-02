# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Ractor compatibility" do
  it "keeps core constants shareable across Ractor boundaries" do
    values = [
      River::JOB_STATE_AVAILABLE,
      River::JOB_STATE_CANCELLED,
      River::JOB_STATE_COMPLETED,
      River::JOB_STATE_DISCARDED,
      River::JOB_STATE_PENDING,
      River::JOB_STATE_RETRYABLE,
      River::JOB_STATE_RUNNING,
      River::JOB_STATE_SCHEDULED,
      River::QUEUE_DEFAULT,
      River::RESUMABLE_CURSOR_METADATA_KEY,
      River::RESUMABLE_STEP_METADATA_KEY,
      River::Client.const_get(:DEFAULT_UNIQUE_STATES, false),
      River::Client.const_get(:REQUIRED_UNIQUE_STATES, false),
      River::Client.const_get(:EMPTY_INSERT_OPTS, false),
      River::Client.const_get(:TAG_RE, false),
      River::UniqueBitmask.const_get(:JOB_STATE_BIT_POSITIONS, false)
    ]

    expect(values).to all(satisfy { |value| Ractor.shareable?(value) })
  end
end
