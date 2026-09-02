# frozen_string_literal: true

module River
  # Registry that maps job kinds to worker objects.
  class Workers
    # Creates an empty worker registry.
    def initialize
      @workers = {}
    end

    # Registers a worker for a job kind and optional aliases, returning self.
    #
    # With one argument, the kind is read from +worker.kind+ or
    # +worker.class.kind+. Pass a kind and worker separately to override it.
    # Kinds and aliases accept symbols or strings.
    def add(kind_or_worker, worker = nil, aliases: [])
      if worker
        kind = kind_or_worker.to_s
      else
        worker = kind_or_worker
        kind = worker.respond_to?(:kind) ? worker.kind.to_s : worker.class.kind.to_s
      end

      candidates = [kind] + aliases.map(&:to_s)
      candidates.each do |candidate|
        raise ArgumentError, "worker for kind #{candidate.inspect} is already registered" if @workers.key?(candidate)
      end

      candidates.each do |candidate|
        @workers[candidate] = worker
      end

      self
    end

    # Returns the worker registered for +kind+, or nil when none is registered.
    def fetch(kind)
      @workers[kind.to_s]
    end

    # Returns true if a worker is registered for +kind+.
    def include?(kind)
      @workers.key?(kind.to_s)
    end

    # Returns the registered job kinds, including aliases.
    def kinds
      @workers.keys.freeze
    end
  end

  # A job being worked, with access to its persisted row and attempt-local
  # metadata changes.
  class Job
    # Client working this job.
    attr_reader :client

    # Persisted JobRow claimed for this attempt.
    attr_reader :row

    def initialize(client, row)
      @client = client
      @metadata_updates = {}
      @row = row
      initialize_resumable_state
    end

    # Returns the job arguments decoded from their persisted JSON.
    def args = row.args

    # Returns persisted metadata merged with changes made during this attempt.
    def metadata = row.metadata.merge(@metadata_updates)

    # Returns a copy of metadata changes waiting to be persisted when work
    # finishes.
    def metadata_updates
      @metadata_updates.dup
    end

    def method_missing(name, ...)
      return row.public_send(name, ...) if row.respond_to?(name)

      super
    end

    # Stores a worker result under the conventional +"output"+ metadata key.
    def output=(value)
      update_metadata("output" => value)
    end

    def respond_to_missing?(name, include_private = false)
      row.respond_to?(name, include_private) || super
    end

    # Merges JSON-compatible values into the job metadata to be persisted when
    # work finishes. Keys are converted to strings. Returns self.
    def update_metadata(values)
      @metadata_updates.merge!(values.transform_keys(&:to_s))
      self
    end
  end

  # Default retry schedule used when a worker does not provide its own policy.
  class DefaultClientRetryPolicy
    # Creates River's default quartic-backoff retry policy. A Random source may
    # be injected to make jitter deterministic.
    def initialize(random: Random)
      @random = random
    end

    # Returns the Time at which +job+ should next be attempted.
    def next_retry(job, _error = nil, now: Time.now.utc)
      error_count = Array(job.errors).length + 1
      seconds = Integer(error_count**4)
      now + seconds + (seconds * (@random.rand * 0.2 - 0.1))
    end
  end
end
