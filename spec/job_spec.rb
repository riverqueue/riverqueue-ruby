require "spec_helper"

describe River::JobArgsHash do
  it "generates a job args based on a hash" do
    args = River::JobArgsHash.new("my_hash_kind", {job_num: 123})
    expect(args.kind).to eq("my_hash_kind")
    expect(args.to_json).to eq(JSON.dump({job_num: 123}))
  end

  it "errors on a nil kind" do
    expect do
      River::JobArgsHash.new(nil, {job_num: 123})
    end.to raise_error(RuntimeError, "kind should be non-nil")
  end

  it "errors on a nil hash" do
    expect do
      River::JobArgsHash.new("my_hash_kind", nil)
    end.to raise_error(RuntimeError, "hash should be non-nil")
  end
end

describe River::AttemptError do
  it "initializes with parameters" do
    now = Time.now

    attempt_error = River::AttemptError.new(
      at: now,
      attempt: 1,
      error: "job failure",
      trace: "error trace"
    )
    expect(attempt_error).to have_attributes(
      at: now,
      attempt: 1,
      error: "job failure",
      trace: "error trace"
    )
  end
end
