# frozen_string_literal: true

module River
  RESUMABLE_CURSOR_METADATA_KEY = "river:resumable_cursor"
  RESUMABLE_STEP_METADATA_KEY = "river:resumable_step"

  # Execution state for resumable steps. Applications normally interact with
  # this through Job#resumable_step and Job#resumable_step_cursor.
  class ResumableState
    attr_reader :all_step_names
    attr_accessor :completed_step
    attr_reader :cursors
    attr_accessor :error
    attr_reader :had_cursors
    attr_accessor :resume_matched
    attr_reader :resume_step
    attr_accessor :step_name

    def initialize(metadata)
      @all_step_names = {}
      @completed_step = nil
      @cursors = (metadata[RESUMABLE_CURSOR_METADATA_KEY] || {}).dup
      @error = nil
      @had_cursors = @cursors.any?
      @resume_step = metadata[RESUMABLE_STEP_METADATA_KEY]
      @step_name = nil

      @resume_matched = @resume_step.to_s.empty?
    end

    def register(name)
      if all_step_names.key?(name)
        self.error = Error.new("duplicate resumable step name #{name.inspect}")
        return false
      end

      all_step_names[name] = true
    end
  end

  class Job
    # Internal runtime boundary: attach progress only to attempts that did not
    # complete, matching River Go's persisted metadata format.
    def __capture_resumable_metadata!
      return unless @resumable_state.completed_step || @resumable_state.cursors.any? || @resumable_state.had_cursors

      if @resumable_state.cursors.any?
        @metadata_updates[RESUMABLE_CURSOR_METADATA_KEY] = @resumable_state.cursors.dup
      elsif @resumable_state.had_cursors
        @metadata_updates[RESUMABLE_CURSOR_METADATA_KEY] = nil
      end

      if @resumable_state.completed_step
        @metadata_updates[RESUMABLE_STEP_METADATA_KEY] = @resumable_state.completed_step
      end
    end

    # Internal runtime boundary: turn a deferred step error into the job's work
    # error after the worker has returned.
    def __finish_resumable_work!
      error = @resumable_state.error
      raise error if error

      if @resumable_state.resume_step && !@resumable_state.resume_matched
        raise Error, "resumable step #{@resumable_state.resume_step.inspect} not found in worker"
      end
    end

    # Immediately checkpoints the current step and cursor progress. Wrap the
    # call in Driver#transaction alongside application writes when an atomic
    # checkpoint is needed.
    def resumable_checkpoint(cursor: RESUMABLE_CURSOR_UNSET)
      step_name = @resumable_state.step_name
      raise Error, "resumable step can only be persisted inside a resumable step" unless step_name
      raise Error, "job must be running" unless row.state == JOB_STATE_RUNNING

      resumable_set_cursor(cursor) unless cursor.equal?(RESUMABLE_CURSOR_UNSET)

      @resumable_state.completed_step = step_name
      updates = {RESUMABLE_STEP_METADATA_KEY => step_name} #: Hash[String, untyped]
      updates[RESUMABLE_CURSOR_METADATA_KEY] = @resumable_state.cursors.dup if @resumable_state.cursors.any?

      updated = client.driver.job_metadata_merge(row.id, updates) || raise(NotFoundError, "job not found: #{row.id}")
      @metadata_updates.merge!(updates)
      @row = updated
    end

    # Records JSON-compatible cursor data for the current step. It is persisted
    # with the failed attempt so that its retry can continue from this value.
    def resumable_set_cursor(cursor)
      step_name = @resumable_state.step_name
      raise Error, "resumable cursor can only be set inside a resumable step" unless step_name

      @resumable_state.cursors[step_name] = JSON.parse(JSON.dump(cursor))
      cursor
    end

    # Runs a named step, skipping it on retry when a previous attempt already
    # completed it. Names accept symbols or strings and must be unique within a
    # worker invocation. Persisted checkpoints always use string names.
    def resumable_step(name, &block)
      run_resumable_step(name.to_s, cursor: false, default: nil, &block)
    end

    # Runs a named step with the cursor saved by #resumable_set_cursor during a
    # previous failed attempt. Names accept symbols or strings.
    def resumable_step_cursor(name, default: nil, &block)
      run_resumable_step(name.to_s, cursor: true, default: default, &block)
    end

    RESUMABLE_CURSOR_UNSET = Object.new.freeze
    private_constant :RESUMABLE_CURSOR_UNSET

    private def initialize_resumable_state
      @resumable_state = ResumableState.new(row.metadata)
    end

    private def run_resumable_step(name, cursor:, default:)
      raise ArgumentError, "resumable step name must be non-empty" if name.empty?
      return if @resumable_state.error
      return unless @resumable_state.register(name)

      unless @resumable_state.resume_matched
        if name == @resumable_state.resume_step
          @resumable_state.completed_step = name
          @resumable_state.resume_matched = true
          return unless cursor && @resumable_state.cursors.key?(name)
        else
          return
        end
      end

      previous_step_name = @resumable_state.step_name
      @resumable_state.step_name = name
      begin
        value = (cursor && @resumable_state.cursors.key?(name)) ? @resumable_state.cursors[name] : default
        result = cursor ? yield(value) : yield
        @resumable_state.completed_step = name
        @resumable_state.cursors.delete(name) if cursor

        result
      rescue => error
        @resumable_state.error = error
        nil
      ensure
        @resumable_state.step_name = previous_step_name
      end
    end
  end
end
