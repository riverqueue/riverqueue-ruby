# frozen_string_literal: true

require "timeout"

module River
  class ClientRuntime
    class Interrupted < StandardError; end

    attr_reader :periodic_jobs

    def initialize(client, driver, config)
      @client = client
      @condition = ConditionVariable.new
      @config = config
      @driver = driver
      @mutex = Mutex.new
      @periodic_jobs = PeriodicJobBundle.new(config.periodic_jobs, wake: method(:wake))
      @producer_threads = {}
      @queue_configs = config.queues.dup
      @removed_queues = {}
      @running = {}
      @started = false
      @stopped = true
      @subscriptions = []
      @threads = []
    end

    def finish_claimed(row, error = nil)
      started_at = Time.now.utc
      job = Job.new(@client, row)
      if error
        finish_failed(row, job, error, started_at)
      else
        now = Time.now.utc
        completed = @driver.job_set_state_if_running(id: row.id, finalized_at: now, now: now, state: JOB_STATE_COMPLETED)
        publish(EVENT_JOB_COMPLETED, completed, started_at) if completed
      end
    end

    def perform_job(id, allow_scheduled: false)
      @mutex.synchronize do
        raise ClientAlreadyStartedError, "synchronous execution requires an idle, stopped client" if @started || @performing

        @performing = true
        @stop_requested = false
      end

      begin
        row = @driver.job_claim(id: id, allow_scheduled: allow_scheduled, attempted_by: @config.id)
        raise ArgumentError, "job #{id} is missing, not runnable, or scheduled in the future" unless row

        @mutex.synchronize { @running[row.id] = {queue: row.queue, thread: Thread.current, working: false} }
        outcome, error = execute(row)
        [@driver.job_get_by_id(id), error, outcome]
      ensure
        @mutex.synchronize { @performing = false }
      end
    end

    def publish_queue(kind, queue)
      event = Event.new(kind, nil, queue, nil)
      @mutex.synchronize { @subscriptions.dup }.each { |subscription| subscription.publish(event) }
    end

    def healthy?
      @mutex.synchronize do
        @stop_requested || (@producer_threads.all? { |name, thread| @removed_queues[name] || thread.alive? } && (!@maintenance_thread || @maintenance_thread.alive?))
      end
    end

    def interrupt_workers
      @mutex.synchronize do
        @running.values.each { |entry| entry[:thread].raise(Interrupted) if entry[:working] }
      end
    end

    def queue_add(name, queue_config)
      name = name.to_s
      queue_config = QueueConfig.new(max_workers: queue_config) unless queue_config.is_a?(QueueConfig)
      raise ArgumentError, "invalid queue name: #{name.inspect}" unless name.match?(QUEUE_NAME_REGEX) && name.length < 128

      queue_config.resolved_fetch_poll_interval(@config)
      should_start = @mutex.synchronize do
        raise ArgumentError, "queue is already configured: #{name}" if @queue_configs.key?(name)

        @queue_configs[name] = queue_config
        @removed_queues.delete(name)
        @started && !@stop_requested
      end

      if should_start
        start_producer(name, queue_config)
        start_maintenance
      end

      wake
      queue_config
    end

    def queue_remove(name)
      name = name.to_s
      producer = @mutex.synchronize do
        raise NotFoundError, "queue is not configured: #{name}" unless @queue_configs.key?(name)

        @removed_queues[name] = true
        @condition.broadcast
        @producer_threads[name]
      end

      producer&.join
      running = @mutex.synchronize do
        @running.values.filter_map { |entry| entry[:thread] if entry[:queue] == name }
      end
      running.each(&:join)

      @mutex.synchronize do
        @queue_configs.delete(name)
        @producer_threads.delete(name)
      end

      true
    end

    def start
      @mutex.synchronize do
        raise ClientAlreadyStartedError, "client is already started" if @started || @performing

        @started = true
        @stop_requested = false
        @stopped = false
      end

      begin
        @queue_configs.each { |name, queue_config| start_producer(name, queue_config) }
        start_maintenance unless @queue_configs.empty?

        self
      rescue
        stop(cancel: true)
        raise
      end
    end

    def started?
      @mutex.synchronize { @started }
    end

    def stop(cancel: false, wait: true)
      threads = @mutex.synchronize do
        return self if @stopped

        @stop_requested = true
        @condition.broadcast
        @running.values.each { |entry| entry[:thread].raise(Interrupted) if cancel && entry[:working] }
        @threads.dup
      end

      return self unless wait

      threads.each(&:join)

      running_threads = @mutex.synchronize { @running.values.map { |entry| entry[:thread] } }
      running_threads.each(&:join)

      @driver.leader_release(@config.id)
      @mutex.synchronize do
        @started = false
        @stopped = true
        @threads.clear
        @producer_threads.clear
        @maintenance_thread = nil
      end

      self
    end

    def stopped?
      @mutex.synchronize { @stopped }
    end

    def subscribe(kinds, buffer_size: 100)
      subscription = Subscription.new(
        kinds,
        buffer_size: buffer_size,
        on_close: method(:remove_subscription)
      )
      @mutex.synchronize { @subscriptions << subscription }
      subscription
    end

    def wake
      @mutex.synchronize { @condition.broadcast }
    end

    private def begin_work(id)
      should_interrupt = @mutex.synchronize do
        entry = @running.fetch(id)
        if @stop_requested
          true
        else
          entry[:working] = true
          false
        end
      end

      raise Interrupted if should_interrupt
    end

    private def check_remote_cancellations(queue)
      entries = @mutex.synchronize { @running.select { |_id, entry| entry[:queue] == queue && entry[:working] } }
      return if entries.empty?

      @driver.job_get_cancelled_ids(entries.keys).each do |id|
        entries.fetch(id)[:thread].raise(JobCancelError)
      end
    end

    private def error_handler_cancel?(error, job)
      return false unless @config.error_handler

      result = if @config.error_handler.respond_to?(:handle_error)
        @config.error_handler.handle_error(error, job)
      else
        @config.error_handler.call(error, job)
      end
      result == :cancel || result == true
    rescue => handler_error
      @config.logger.error("River error handler failed: #{handler_error.full_message}")
      false
    end

    private def execute(row)
      started_at = Time.now.utc
      job = Job.new(@client, row)
      begin
        worker = resolve_worker(row.kind)
        begin_work(row.id)
        begin
          Thread.handle_interrupt(Interrupted => :immediate, JobCancelError => :immediate) do
            invoke_worker(worker, job)
          end
        ensure
          finish_work(row.id)
        end

        job.__finish_resumable_work!
        finalize_hooks = @config.plugins.any? { |plugin| plugin.respond_to?(:job_finalize) }
        if finalize_hooks
          raise JobCancelError if @driver.job_get_cancelled_ids([row.id]).include?(row.id)

          if invoke_plugins(:job_finalize, job, JOB_STATE_COMPLETED).include?(:delete)
            @driver.job_delete_if_running(row.id)
            return [:deleted, nil]
          end
        end

        completed_at = Time.now.utc
        completed = if finalize_hooks
          @driver.job_set_state_if_running(id: row.id, finalized_at: completed_at, metadata: job.metadata_updates, now: completed_at, state: JOB_STATE_COMPLETED)
        else
          result = @driver.job_complete(id: row.id, finalized_at: completed_at, metadata: job.metadata_updates, now: completed_at)
          case result
          when :cancelled then raise JobCancelError
          else result
          end
        end
        publish(EVENT_JOB_COMPLETED, completed, started_at) if completed

        [:completed, nil]
      rescue JobSnoozeError => error
        job.__capture_resumable_metadata!
        [finish_snoozed(row, job, error, started_at), error]
      rescue JobCancelError => error
        job.__capture_resumable_metadata!
        finish_failed(row, job, error, started_at, cancelled: true)
        [:cancelled, error]
      rescue Interrupted => error
        job.__capture_resumable_metadata!
        interrupted = @driver.job_set_state_if_running(
          id: row.id,
          attempt: [row.attempt - 1, 0].max,
          metadata: job.metadata_updates,
          scheduled_at: Time.now.utc,
          state: JOB_STATE_AVAILABLE
        )
        publish(EVENT_JOB_INTERRUPTED, interrupted, started_at) if interrupted

        [(interrupted&.state == JOB_STATE_CANCELLED) ? :cancelled : :interrupted, error]
      rescue => error
        job.__capture_resumable_metadata!
        [finish_failed(row, job, error, started_at, worker: worker), error]
      ensure
        @mutex.synchronize do
          @running.delete(row.id)
          @condition.broadcast
        end
      end
    end

    private def finish_failed(row, job, error, started_at, cancelled: false, worker: nil)
      cancelled ||= error_handler_cancel?(error, job)
      now = Time.now.utc
      attempt_error = AttemptError.new(
        at: started_at,
        attempt: row.attempt,
        error: error.message,
        trace: Array(error.backtrace).join("\n")
      )
      final = cancelled || row.attempt >= row.max_attempts || !retry_allowed?(worker, job, error)
      state = if cancelled
        JOB_STATE_CANCELLED
      elsif final
        JOB_STATE_DISCARDED
      else
        JOB_STATE_RETRYABLE
      end
      scheduled_at = final ? nil : next_retry(row, error, now, worker: worker)
      state = JOB_STATE_AVAILABLE if scheduled_at && scheduled_at <= now + 5

      updated = @driver.job_set_state_if_running(
        id: row.id,
        error: attempt_error,
        finalized_at: final ? now : nil,
        metadata: job.metadata_updates,
        now: now,
        scheduled_at: scheduled_at,
        state: state
      )
      event = cancelled ? EVENT_JOB_CANCELLED : EVENT_JOB_FAILED
      publish(event, updated, started_at) if updated

      case updated&.state || state
      when JOB_STATE_CANCELLED then :cancelled
      when JOB_STATE_DISCARDED then :discarded
      else :retried
      end
    end

    private def finish_snoozed(row, job, error, started_at)
      scheduled_at = Time.now.utc + error.duration
      state = (error.duration <= 5) ? JOB_STATE_AVAILABLE : JOB_STATE_SCHEDULED
      metadata = job.metadata_updates.merge("snoozes" => row.metadata.fetch("snoozes", 0).to_i + 1)
      updated = @driver.job_set_state_if_running(
        id: row.id,
        attempt: [row.attempt - 1, 0].max,
        metadata: metadata,
        scheduled_at: scheduled_at,
        state: state
      )
      publish(EVENT_JOB_SNOOZED, updated, started_at) if updated
      (updated&.state == JOB_STATE_CANCELLED) ? :cancelled : :snoozed
    end

    private def finish_work(id)
      @mutex.synchronize do
        entry = @running[id]
        entry[:working] = false if entry
      end
    end

    private def invoke_plugins(name, ...)
      @config.plugins.filter_map { |plugin| plugin.public_send(name, ...) if plugin.respond_to?(name) }
    end

    private def invoke_worker(worker, job)
      return perform_work(worker, job) if @config.plugins.empty?

      operation = -> do
        error = nil
        begin
          invoke_plugins(:work_begin, job)
          perform_work(worker, job)
        rescue => error
          raise
        ensure
          invoke_plugins(:work_end, job, error)
        end
      end
      @config.plugins.reverse_each do |plugin|
        next unless plugin.respond_to?(:work)

        next_operation = operation
        operation = -> { plugin.work(job, next_operation) }
      end

      operation.call
    end

    private def launch(row)
      gate = ::Queue.new
      thread = Thread.new do
        gate.pop
        begin
          Thread.handle_interrupt(Interrupted => :never, JobCancelError => :never) { execute(row) }
        rescue Interrupted, JobCancelError
          # A late asynchronous interrupt may become pending after work has
          # already finalized. The database transition won that race.
        end
      end

      @mutex.synchronize { @running[row.id] = {queue: row.queue, thread: thread, working: false} }
      gate.push(true)
    end

    private def maintenance_loop
      leader = false
      next_schedule = next_rescue = next_cleanup = Time.at(0)
      until stopping?
        now = Time.now.utc
        leader = leader ? @driver.leader_renew(@config.id, now: now) : @driver.leader_acquire(@config.id, now: now)
        if leader
          if now >= next_schedule
            @driver.job_schedule(now: now)
            run_periodic(now)
            @config.maintenance_services.each { |service| service.run(@client, @driver, now) }
            next_schedule = now + 5
          end

          if now >= next_rescue
            @driver.job_rescue_stuck(horizon: now - 3_600, now: now, retry_policy: @config.retry_policy)
            next_rescue = now + 30
          end

          if now >= next_cleanup
            @driver.job_delete_finalized(now: now, retention: {
              JOB_STATE_CANCELLED => @config.cancelled_job_retention_period,
              JOB_STATE_COMPLETED => @config.completed_job_retention_period,
              JOB_STATE_DISCARDED => @config.discarded_job_retention_period
            })
            next_cleanup = now + 30
          end
        end

        wait(5)
      end
    rescue => error
      @config.logger.error("River maintenance stopped: #{error.full_message}")
      wait(5)
      retry unless stopping?
    end

    private def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    private def next_retry(row, error, now, worker: nil)
      worker ||= @config.workers.fetch(row.kind)
      custom = worker.next_retry(row, error) if worker.respond_to?(:next_retry)

      retry_at = custom || @config.retry_policy.next_retry(row, error, now: now)
      raise ArgumentError, "next_retry must return a Time" unless retry_at.is_a?(Time)

      (retry_at < now) ? DefaultClientRetryPolicy.new.next_retry(row, error, now: now) : retry_at
    rescue => retry_error
      @config.logger.error("River retry scheduling failed; using default backoff: #{retry_error.full_message}")
      DefaultClientRetryPolicy.new.next_retry(row, error, now: now)
    end

    private def perform_work(worker, job)
      timeout = worker.respond_to?(:timeout) ? worker.timeout(job) : @config.job_timeout
      timeout = @config.job_timeout if timeout == 0
      timeout ? Timeout.timeout(timeout) { worker.work(job) } : worker.work(job)
    end

    private def producer_loop(queue, queue_config)
      cooldown = queue_config.resolved_fetch_cooldown(@config)
      last_fetch = 0.0
      poll_interval = queue_config.resolved_fetch_poll_interval(@config)
      loop do
        break if queue_stopping?(queue)

        check_remote_cancellations(queue)
        queue_row = @driver.queue_get(queue)
        capacity = queue_config.max_workers - running_count(queue)
        if capacity.positive? && !queue_row&.paused_at
          sleep_for = cooldown - (monotonic_now - last_fetch)
          wait([sleep_for, 0].max) if sleep_for.positive?
          break if queue_stopping?(queue)

          jobs = @driver.job_get_available(attempted_by: @config.id, max: capacity, queue: queue)
          last_fetch = monotonic_now
          jobs.each { |job| launch(job) }
          next unless jobs.empty?
        end

        wait(poll_interval)
      end
    rescue => error
      @config.logger.error("River producer for #{queue.inspect} stopped: #{error.full_message}")
      wait(poll_interval || @config.fetch_poll_interval)
      retry unless queue_stopping?(queue)
    end

    private def publish(kind, job, started_at)
      kind = EVENT_JOB_CANCELLED if job.state == JOB_STATE_CANCELLED
      completed_at = Time.now.utc
      stats = JobStatistics.new(0, started_at - job.scheduled_at, completed_at - started_at)
      event = Event.new(kind, job, nil, stats)
      @mutex.synchronize { @subscriptions.dup }.each { |subscription| subscription.publish(event) }
    end

    private def queue_stopping?(queue)
      @mutex.synchronize { @stop_requested || @removed_queues[queue] }
    end

    private def remove_subscription(subscription)
      @mutex.synchronize { @subscriptions.delete(subscription) }
    end

    private def resolve_worker(kind)
      worker = @config.workers.fetch(kind)
      raise UnknownJobKindError, kind unless worker
      worker.is_a?(Class) ? worker.new : worker
    end

    private def retry_allowed?(worker, job, error)
      !worker.respond_to?(:retry?) || worker.retry?(job, error)
    rescue => retry_error
      @config.logger.error("River retry? hook failed; allowing retry: #{retry_error.full_message}")
      true
    end

    private def run_periodic(now)
      @periodic_jobs.due(now).each do |periodic_job|
        value = periodic_job.constructor.call
        next unless value

        args, opts = value.is_a?(Array) ? value : [value, nil]
        @client.insert(args, insert_opts: opts || InsertOpts.new)
      rescue => error
        @config.logger.error("River periodic job failed to insert: #{error.full_message}")
      end
    end

    private def running_count(queue)
      @mutex.synchronize { @running.count { |_id, entry| entry[:queue] == queue } }
    end

    private def start_maintenance
      @mutex.synchronize do
        return if @maintenance_thread&.alive?

        thread = Thread.new { maintenance_loop }
        @maintenance_thread = thread
        @threads << thread
      end
    end

    private def start_producer(name, queue_config)
      @driver.queue_upsert(name)
      thread = Thread.new { producer_loop(name, queue_config) }
      @mutex.synchronize do
        @producer_threads[name] = thread
        @threads << thread
      end
    end

    private def stopping?
      @mutex.synchronize { @stop_requested }
    end

    private def wait(duration)
      @mutex.synchronize { @condition.wait(@mutex, duration) unless @stop_requested }
    end
  end
end
