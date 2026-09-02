# frozen_string_literal: true

module River
  # Definition of a recurring job and the schedule used to construct it.
  class PeriodicJob
    # Callable that produces job arguments, or an arguments/options pair.
    attr_reader :constructor

    # Stable string identifier used for removal and durable Pro scheduling.
    attr_reader :id

    # Whether the job should run immediately when its scheduler starts.
    attr_reader :run_on_start

    # Object or callable that computes the next run time.
    attr_reader :schedule

    # Creates a periodic job. +schedule+ may respond to +next(time)+ or be a
    # callable, and +constructor+ is called whenever the job is due. +id+ accepts
    # a symbol or string; nil leaves the registration anonymous.
    def initialize(schedule:, constructor:, id: nil, run_on_start: false)
      @constructor = constructor
      @id = id&.to_s
      @run_on_start = run_on_start
      @schedule = schedule
    end

    # Returns the next scheduled Time after +now+.
    def next_at(now)
      schedule.respond_to?(:next) ? schedule.next(now) : schedule.call(now)
    end
  end

  # A fixed-duration schedule suitable for PeriodicJob.
  class PeriodicInterval
    # Creates an interval measured in seconds.
    def initialize(seconds)
      @seconds = Float(seconds) || raise(ArgumentError, "period must be numeric")
      raise ArgumentError, "period must be greater than zero" unless @seconds.positive?
    end

    # Returns the next Time one interval after +time+.
    def next(time)
      time + @seconds
    end
  end

  # Thread-safe collection used to change a client's periodic jobs at runtime.
  class PeriodicJobBundle
    def initialize(jobs, wake:)
      @jobs = {}
      @mutex = Mutex.new
      @next_handle = 0
      @wake = wake
      add_many(jobs)
    end

    # Adds a periodic job and returns a handle that can be passed to #remove.
    def add(job)
      @mutex.synchronize do
        raise ArgumentError, "periodic job ID is already registered: #{job.id}" if job.id && @jobs.values.any? { |entry| entry[:job].id == job.id }

        @next_handle += 1
        @jobs[@next_handle] = {job: job, next_at: job.run_on_start ? Time.now.utc : job.next_at(Time.now.utc)}
        @wake.call
        @next_handle
      end
    end

    # Adds periodic jobs and returns their handles in input order.
    def add_many(jobs)
      jobs.map { |job| add(job) }
    end

    # Removes all periodic jobs from the bundle.
    def clear
      @mutex.synchronize { @jobs.clear }
    end

    def due(now)
      @mutex.synchronize do
        @jobs.values.filter_map do |entry|
          next if entry[:next_at] > now

          entry[:next_at] = entry[:job].next_at(now)
          entry[:job]
        end
      end
    end

    # Removes the job associated with +handle+, returning its internal entry or
    # nil when no such handle exists.
    def remove(handle)
      @mutex.synchronize { @jobs.delete(handle) }
    end

    # Removes the periodic job with +id+. Returns whether a job was removed.
    def remove_by_id(id)
      id = id&.to_s
      @mutex.synchronize do
        pair = @jobs.find { |_handle, entry| entry[:job].id == id }
        !!(pair && @jobs.delete(pair.first))
      end
    end
  end
end
