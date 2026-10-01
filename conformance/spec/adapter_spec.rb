# frozen_string_literal: true

require_relative "../adapter"

RSpec.describe RiverConformance::Adapter do
  let(:reference) { ENV.fetch("RIVER_PATH") }
  let(:contract) { JSON.parse(File.read(File.join(reference, "conformance/adapter/contract.json"))) }
  let(:profile) { JSON.parse(File.read(File.join(reference, "conformance/adapter/profiles/insert-only.json"))) }
  let(:adapter) do
    described_class.allocate.tap do |adapter|
      adapter.instance_variable_set(:@contract, contract)
      adapter.instance_variable_set(:@profile, profile)
      adapter.instance_variable_set(:@schema, RiverConformance::Schema.new(contract))
      adapter.instance_variable_set(:@manifest, JSON.parse(File.read(File.join(reference, "conformance/manifest.json"))))
      adapter.instance_variable_set(:@application_name, "river-conformance-ruby-unit")
      adapter.instance_variable_set(:@client, River::Client.new(Object.new))
      adapter.instance_variable_set(:@transactions, {})
    end
  end

  def rpc(method, params = {}, id: 1)
    RiverConformance.handle_line(adapter, JSON.generate(jsonrpc: "2.0", id: id, method: method, params: params))
  end

  it "advertises exactly the implemented profile and rejects other methods" do
    result = rpc("handshake").fetch(:result)
    expect(result).to include(implementation: "ruby", profile: "insert-only-v1", backend: "postgres",
      methods: profile.fetch("methods"), capabilities: profile.fetch("capabilities"))
    (contract.fetch("methods").map { |method| method.fetch("name") } - profile.fetch("methods")).each do |method|
      expect(rpc(method).fetch(:error).fetch(:code)).to eq(-32601)
    end
  end

  it "rejects unknown and mistyped parameters, including nested batch options" do
    [
      ["handshake", {extra: true}],
      ["insert", []],
      ["insert", {message: 1}],
      ["insert", {behavior: "unknown"}],
      ["insert", {duration_ms: -1}],
      ["insert", {opts: {unique: {by_args: "true"}}}],
      ["insert_many", {jobs: [{opts: {unknown: 1}}]}],
      ["tx_begin", {}],
      ["tx_begin", {handle: ""}]
    ].each do |method, params|
      expect(rpc(method, params).fetch(:error).fetch(:code)).to eq(-32602)
    end
  end

  it "distinguishes malformed JSON and invalid requests" do
    expect(RiverConformance.handle_line(adapter, "{").fetch(:error).fetch(:code)).to eq(-32700)
    ["[]", "null", "{}", '{"jsonrpc":"2.0","id":null,"method":"handshake"}',
      '{"jsonrpc":"2.0","id":1.5,"method":"handshake"}',
      '{"jsonrpc":"2.0","id":1,"method":"handshake","extra":true}'].each do |line|
      expect(RiverConformance.handle_line(adapter, line).fetch(:error).fetch(:code)).to eq(-32600)
    end
    expect(rpc("handshake", {}, id: 9_007_199_254_740_993).fetch(:id)).to eq(9_007_199_254_740_993)
  end

  it "classifies missing handles, rejected batches, and unsupported schemas" do
    expect(rpc("tx_commit", {handle: "missing"}).fetch(:error).fetch(:code)).to eq(-32001)
    expect(rpc("insert_many", {jobs: []}).fetch(:error).fetch(:code)).to eq(-32002)
    expect(rpc("insert", {schema: "custom"}).fetch(:error).fetch(:code)).to eq(-32004)
  end

  it "computes hashes from raw request values and ignores fixture expectations" do
    line = '{"jsonrpc":"2.0","id":1,"method":"unique_key","params":{"args":{"n":-0},"kind":"conformance_all_args","now":"2026-01-02T03:04:05Z","queue":"default","expected_sha256":"not the result","options":{"by_args":true,"by_period_nanos":0,"by_queue":false,"exclude_kind":false}}}'
    result = RiverConformance.handle_line(adapter, line).fetch(:result)
    expect(result).to eq(sha256: Digest::SHA256.hexdigest('&kind=conformance_all_args&args={"n":-0}'), state_mask: 245)
  end

  it "keeps the protocol duplicate field independent of the Ruby predicate name" do
    row = Struct.new(:id).new(1)
    client = Object.new
    client.define_singleton_method(:insert_many) do |_items|
      [false, true].map { |duplicate| River::JobInsertResult.new(row, unique_skipped_as_duplicated: duplicate) }
    end
    adapter.instance_variable_set(:@client, client)
    adapter.define_singleton_method(:normalize) { |job| {id: job.id} }

    expect(rpc("insert_many", {jobs: [{}, {}]}).fetch(:result)).to eq(results: [
      {job: {id: 1}, unique_skipped_as_duplicate: false},
      {job: {id: 1}, unique_skipped_as_duplicate: true}
    ])
  end

  it "normalizes timestamps without losing subsecond precision" do
    expect(adapter.timestamp(Time.iso8601("2026-01-02T03:04:05.123456000+05:30"))).to eq("2026-01-01T21:34:05.123456Z")
    expect(adapter.timestamp(Time.utc(2026))).to eq("2026-01-01T00:00:00Z")
    expect(adapter.timestamp(nil)).to be_nil
  end

  it "preserves an existing transaction when a duplicate handle is rejected" do
    driver = Object.new
    driver.define_singleton_method(:transaction) { |&block| block.call }
    released = Queue.new
    adapter.instance_variable_set(:@driver, driver)
    adapter.instance_variable_set(:@release_connection, -> { released << true })
    expect(rpc("tx_begin", {handle: "first"}).fetch(:result)).to eq({})
    expect(rpc("tx_begin", {handle: "first"}).fetch(:error).fetch(:code)).to eq(-32002)
    expect(rpc("tx_commit", {handle: "first"}).fetch(:result)).to eq({})
    expect(released.pop).to eq(true)
    expect(adapter.instance_variable_get(:@transactions)).to be_empty
  ensure
    transaction = adapter.instance_variable_get(:@transactions)["first"]
    adapter.finish_transaction("first", :commit) if transaction
  end

  it "discards a transaction handle when opening its transaction fails" do
    driver = Object.new
    driver.define_singleton_method(:transaction) { raise ArgumentError, "cannot begin" }
    released = Queue.new
    adapter.instance_variable_set(:@driver, driver)
    adapter.instance_variable_set(:@release_connection, -> { released << true })
    expect(rpc("tx_begin", {handle: "failed"}).fetch(:error).fetch(:code)).to eq(-32002)
    expect(adapter.instance_variable_get(:@transactions)).to be_empty
    expect(released.pop).to eq(true)
  end
end
