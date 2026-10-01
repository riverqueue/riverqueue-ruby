# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "riverqueue"
require "riverqueue-sequel"
require "riverqueue-activerecord"
require_relative "schema"

module RiverConformance
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class ProtocolError < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  class Adapter
    Args = Struct.new(:kind, :encoded) do
      def to_json = encoded
    end

    def initialize
      upstream = ENV.fetch("RIVER_PATH")
      @profile = JSON.parse(File.read(File.join(upstream, "conformance/adapter/profiles/insert-only.json")))
      raise "Only insert-only-v1 on PostgreSQL is implemented" unless ENV.fetch("RIVER_CONFORMANCE_PROFILE", "insert-only-v1") == "insert-only-v1" && ENV.fetch("RIVER_CONFORMANCE_DATABASE_KIND", "postgres") == "postgres"

      @contract = JSON.parse(File.read(File.join(upstream, "conformance/adapter/contract.json")))
      @manifest = JSON.parse(File.read(File.join(upstream, "conformance/manifest.json")))
      @schema = Schema.new(@contract)
      @application_name = ENV.fetch("RIVER_CONFORMANCE_APPLICATION_NAME", "river-conformance-ruby")
      case ENV.fetch("RIVER_CONFORMANCE_DRIVER", "sequel")
      when "sequel"
        @database = Sequel.connect(ENV.fetch("RIVER_CONFORMANCE_DATABASE_URL"), max_connections: 10,
          after_connect: ->(connection) { connection.exec_params("SELECT set_config('application_name', $1, false)", [@application_name]) })
        @driver = River::Driver::Sequel.new(@database)
        @disconnect = -> { @database.disconnect }
        @release_connection = -> {}
      when "activerecord"
        Record.establish_connection(url: ENV.fetch("RIVER_CONFORMANCE_DATABASE_URL"), pool: 10,
          variables: {application_name: @application_name})
        @driver = River::Driver::ActiveRecord.new(connection_class: Record)
        @disconnect = -> { Record.connection_pool.disconnect! }
        @release_connection = -> { Record.connection_pool.release_connection }
      else
        raise "RIVER_CONFORMANCE_DRIVER must be sequel or activerecord"
      end
      @client = River::Client.new(@driver, config: River::Config.new(logger: Logger.new($stderr)))
      @transactions = {}
    end

    def close
      @transactions.keys.each { |handle| finish_transaction(handle, :rollback) }
      @disconnect.call
    end

    def dispatch(method, params, raw_params: JSON.generate(params))
      raise ProtocolError.new(-32601, "unknown method #{method}") unless @profile.fetch("methods").include?(method)

      @schema.check(method, params)
      case method
      when "handshake"
        {
          adapter_version: @contract.fetch("adapter_version"), application_name: @application_name,
          backend: "postgres", capabilities: @profile.fetch("capabilities"), implementation: "ruby",
          implementation_version: Gem.loaded_specs.fetch("riverqueue").version.to_s,
          methods: @profile.fetch("methods"), migration_lines: {@manifest.fetch("migration").fetch("line") => @manifest.fetch("migration").fetch("latest")},
          profile: @profile.fetch("name"), protocol_revision: @profile.fetch("protocol_revision")
        }
      when "insert" then insert(params)
      when "insert_many" then insert_many(params.fetch("jobs"))
      when "unique_key" then unique_key(params, raw_params)
      when "tx_begin" then begin_transaction(params.fetch("handle"))
      when "tx_commit" then finish_transaction(params.fetch("handle"), :commit)
      when "tx_rollback" then finish_transaction(params.fetch("handle"), :rollback)
      when "tx_insert", "tx_insert_many"
        transaction = transaction(params.fetch("handle"))
        operation = (method == "tx_insert") ? -> { insert(params.fetch("job")) } : -> { insert_many(params.fetch("jobs")) }
        transaction.fetch(:commands) << operation
        receive(transaction)
      end
    end

    def insert(params)
      raise ProtocolError.new(-32004, "custom schemas are not exposed by this adapter yet") unless params.fetch("schema", "").empty?

      args, options = insert_params(params)
      normalize(@client.insert(args, insert_opts: options).job)
    end

    def insert_many(jobs)
      items = jobs.map do |job|
        args, options = insert_params(job)
        River::InsertManyParams.new(args, insert_opts: options)
      end
      {results: @client.insert_many(items).map { |result| {job: normalize(result.job), unique_skipped_as_duplicate: result.unique_skipped_as_duplicate?} }}
    end

    def insert_params(params)
      args = River::JobArgsHash.new("conformance_echo", {
        behavior: params.fetch("behavior", ""), duration_ms: params.fetch("duration_ms", 0), message: params.fetch("message", "")
      })
      opts = params.fetch("opts", {})
      unique = opts.fetch("unique", {})
      options = River::InsertOpts.new(max_attempts: opts["max_attempts"], metadata: opts["metadata"], priority: opts["priority"],
        queue: opts["queue"], scheduled_at: opts["scheduled_at"] && Time.iso8601(opts.fetch("scheduled_at")),
        state: opts["pending"] ? :pending : nil, tags: opts["tags"],
        unique_opts: River::UniqueOpts.new(by_args: unique["by_args"],
          by_period: unique.key?("by_period_ms") ? Rational(unique.fetch("by_period_ms"), 1000) : nil,
          by_queue: unique["by_queue"], by_state: unique["by_state"], exclude_kind: unique["exclude_kind"]))
      [args, options]
    end

    def unique_key(params, raw_params)
      options = params.fetch("options")
      fields = case params.fetch("kind")
      when "conformance_selected_args" then [[:account, :id], [:account, :region], :label, "path/key"]
      when "conformance_dotted_selected_args" then ["@user", "!x", "{x}", "[x]", ":id", [:user, :id], "user.id", "a*b?c#d|e", "é"]
      else true
      end
      args = Args.new(params.fetch("kind"), River::UniqueArgs.members(raw_params).fetch("args"))
      opts = River::InsertOpts.new(queue: params.fetch("queue"), scheduled_at: Time.iso8601(params["scheduled_at"] || params.fetch("now")),
        unique_opts: River::UniqueOpts.new(by_args: options.fetch("by_args") && fields,
          by_period: options.fetch("by_period_nanos").positive? ? Rational(options.fetch("by_period_nanos"), 1_000_000_000) : nil,
          by_queue: options.fetch("by_queue"), by_state: options["by_state"], exclude_kind: options.fetch("exclude_kind")))
      # This codec-only operation uses the very same preparation as insert; it
      # must never implement a separate, adapter-only hashing algorithm.
      prepared = @client.send(:make_insert_params, args, opts)
      {sha256: prepared.unique_key.unpack1("H*"), state_mask: prepared.unique_states.to_i(2)}
    end

    def normalize(row)
      {
        args: row.args, attempt: row.attempt, attempted_at: timestamp(row.attempted_at), attempted_by: row.attempted_by || [],
        created_at: timestamp(row.created_at), errors: (row.errors || []).map { |error| {at: timestamp(error.at), attempt: error.attempt, error: error.error, trace: error.trace} },
        finalized_at: timestamp(row.finalized_at), id: row.id, kind: row.kind, max_attempts: row.max_attempts,
        metadata: row.metadata.except("river:unique_nonce"), priority: row.priority, queue: row.queue,
        scheduled_at: timestamp(row.scheduled_at), state: row.state, tags: row.tags || [],
        unique_key: row.unique_key&.unpack1("H*"), unique_states: row.unique_key ? row.unique_states.sort : nil
      }
    end

    def timestamp(time)
      time&.getutc&.iso8601(9)&.sub(/(\.\d*?)0+Z\z/, '\1Z')&.sub(".Z", "Z")
    end

    # Sequel transactions are thread-local. Keep each transaction's entire
    # lifetime inside its native block, including operations from later RPCs.
    def begin_transaction(handle)
      raise ProtocolError.new(-32002, "transaction already exists") if @transactions.key?(handle)

      transaction = {commands: Queue.new, responses: Queue.new}
      transaction[:thread] = Thread.new do
        @driver.transaction do
          transaction[:responses] << [:ok, {}]
          loop do
            command = transaction[:commands].pop
            break if command == :commit
            raise @driver.rollback_exception if command == :rollback

            begin
              transaction[:responses] << [:ok, command.call]
            rescue => error
              transaction[:responses] << [:error, error]
            end
          end
        end
        transaction[:responses] << [:ok, {}]
      rescue => error
        transaction[:responses] << [:error, error]
      ensure
        @release_connection.call
      end
      @transactions[handle] = transaction
      begin
        receive(transaction)
      rescue
        @transactions.delete(handle)
        raise
      end
    end

    def transaction(handle)
      @transactions.fetch(handle) { raise ProtocolError.new(-32001, "unknown transaction") }
    end

    def finish_transaction(handle, action)
      transaction = transaction(handle)
      @transactions.delete(handle)
      transaction.fetch(:commands) << action
      result = receive(transaction)
      transaction.fetch(:thread).join
      result
    end

    def receive(transaction)
      status, result = transaction.fetch(:responses).pop
      raise result if status == :error

      result
    end
  end

  def self.handle_line(adapter, line)
    id = nil
    request = JSON.parse(line)
    valid = request.is_a?(Hash) && request["jsonrpc"] == "2.0" &&
      request["method"].is_a?(String) && !request["method"].empty? &&
      (request["id"].is_a?(Integer) || request["id"].is_a?(String)) &&
      (request.keys - %w[id jsonrpc method params]).empty?
    raise ProtocolError.new(-32600, "invalid JSON-RPC request") unless valid

    id = request["id"]
    raw_params = River::UniqueArgs.members(line).fetch("params", "{}")
    result = adapter.dispatch(request.fetch("method"), request.fetch("params", {}), raw_params: raw_params)
    {jsonrpc: "2.0", id: id, result: result}
  rescue => error
    code = case error
    when ProtocolError then error.code
    when JSON::ParserError then -32700
    when Sequel::DatabaseError, ActiveRecord::StatementInvalid then -32003
    when ArgumentError, River::Error then -32002
    else -32000
    end
    warn error.full_message if code == -32000
    {jsonrpc: "2.0", id: id, error: {code: code, message: error.message}}
  end

  def self.run
    adapter = Adapter.new
    $stdout.sync = true
    $stdin.each_line { |line| puts JSON.generate(handle_line(adapter, line)) }
  ensure
    adapter&.close
  end
end

RiverConformance.run if $PROGRAM_NAME == __FILE__
