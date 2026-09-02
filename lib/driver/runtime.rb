# frozen_string_literal: true

require "time"

module River::Driver
  # Database operations used by River's worker runtime. Driver gems implement a
  # small set of raw SQL primitives and include this module so the state machine
  # stays identical across ActiveRecord and Sequel.
  module Runtime
    def job_cancel(id, now: Time.now.utc)
      original_id = Integer(id)
      updated_id = runtime_returning_ids(<<~SQL).first
        UPDATE river_job
        SET state = CASE WHEN state = 'running' THEN state ELSE 'cancelled' END,
            finalized_at = CASE WHEN state = 'running' THEN finalized_at ELSE #{runtime_time(now)} END,
            metadata = #{runtime_merge_metadata("cancel_attempted_at" => now.iso8601(6))}
        WHERE id = #{original_id}
          AND state NOT IN ('cancelled', 'completed', 'discarded')
          AND finalized_at IS NULL
        RETURNING id
      SQL
      job_get_by_id(updated_id || original_id)
    end

    def job_claim(id:, attempted_by:, allow_scheduled: false, now: Time.now.utc)
      predicate = "id = #{Integer(id)} AND state IN ('available', 'retryable', 'scheduled')"
      predicate += " AND scheduled_at <= #{runtime_time(now)}" unless allow_scheduled

      runtime_claim_jobs(predicate, 1, attempted_by, now).first
    end

    # Drivers may combine the cancellation probe and completion atomically.
    # :cancelled asks the runtime to apply its normal cancellation/error hooks.
    def job_complete(id:, finalized_at:, metadata: nil, now: Time.now.utc)
      id = Integer(id)
      return :cancelled if job_get_cancelled_ids([id]).include?(id)

      job_set_state_if_running(id: id, finalized_at: finalized_at, metadata: metadata, now: now, state: "completed")
    end

    def job_delete(id)
      existing = job_get_by_id(id)
      return nil unless existing
      return existing if existing.state == River::JOB_STATE_RUNNING

      deleted_id = runtime_returning_ids("DELETE FROM river_job WHERE id = #{Integer(id)} AND state != 'running' RETURNING id").first
      deleted_id ? existing : job_get_by_id(id)
    end

    def job_delete_finalized(retention:, now: Time.now.utc, max: 1_000)
      clauses = retention.filter_map do |state, seconds|
        next unless seconds

        "(state = #{runtime_quote(state.to_s)} AND finalized_at < #{runtime_time(now - seconds)})"
      end

      return 0 if clauses.empty?

      ids = runtime_query_rows(<<~SQL).map { |row| runtime_value(row, :id).to_i }
        SELECT id FROM river_job WHERE #{clauses.join(" OR ")} ORDER BY id LIMIT #{Integer(max)}
      SQL
      return 0 if ids.empty?

      runtime_returning_ids(<<~SQL).length
        DELETE FROM river_job
        WHERE id IN (#{ids.join(",")}) AND (#{clauses.join(" OR ")})
        RETURNING id
      SQL
    end

    def job_delete_if_running(id)
      runtime_returning_ids("DELETE FROM river_job WHERE id = #{Integer(id)} AND state = 'running' RETURNING id").any?
    end

    def job_delete_many(params)
      transaction do
        jobs = job_list(params).reject { |job| job.state == River::JOB_STATE_RUNNING }
        next [] if jobs.empty?

        ids = jobs.map(&:id)
        deleted = runtime_returning_ids(<<~SQL)
          DELETE FROM river_job
          WHERE id IN (#{ids.join(",")}) AND state != 'running'
          RETURNING id
        SQL
        jobs.select { |job| deleted.include?(job.id) }
      end
    end

    def job_get_available(queue:, max:, attempted_by:, now: Time.now.utc)
      runtime_claim_jobs("state = 'available' AND queue = #{runtime_quote(queue)} AND scheduled_at <= #{runtime_time(now)}", max, attempted_by, now)
    end

    def job_get_cancelled_ids(ids)
      return [] if ids.empty?

      runtime_query_rows("SELECT id FROM river_job WHERE id IN (#{ids.map { |id| Integer(id) }.join(",")}) AND (#{runtime_cancel_attempted}) ORDER BY id")
        .map { |row| runtime_value(row, :id).to_i }
    end

    def job_list(params = nil)
      params ||= River::JobListParams.new
      return runtime_job_list_without_params if params == :all

      clauses = [] #: Array[String]
      clauses << runtime_cursor_clause(params) if params.after
      clauses << "id #{(params.sort_order == :asc) ? ">" : "<"} #{Integer(params.after_id)}" if params.after_id
      clauses << runtime_in_clause("id", params.ids.map { |value| Integer(value) }) if params.ids&.any?
      clauses << runtime_in_clause("kind", params.kinds) if params.kinds&.any?
      clauses << runtime_in_clause("priority", params.priorities.map { |value| Integer(value) }) if params.priorities&.any?
      clauses << runtime_in_clause("queue", params.queues) if params.queues&.any?
      clauses << runtime_in_clause("state", params.states) if params.states&.any?

      finalized = params.sort_by == :finalized_at && params.states&.length == 1 &&
        %w[cancelled completed discarded].include?(params.states.first)
      # Schemas require finalized timestamps for terminal states. Spell this out
      # so PostgreSQL can use the partial (state, finalized_at) index.
      clauses << "finalized_at IS NOT NULL" if finalized
      # Explicit NULLS LAST prevents a backward index scan, even when there are
      # no nulls. Only request it for timestamps that can actually be null.
      null_order = (params.sort_by == :finalized_at && !finalized) ? " NULLS LAST" : ""

      params.metadata&.each { |key, value| clauses << runtime_metadata_equals(key, value) }
      Array(params.tags_all).each { |tag| clauses << runtime_tag_contains(tag) }
      if params.tags_any&.any?
        clauses << "(" + params.tags_any.map { |tag| runtime_tag_contains(tag) }.join(" OR ") + ")"
      end

      where = clauses.empty? ? "" : "WHERE #{clauses.join(" AND ")}"
      runtime_job_rows(<<~SQL)
        #{where}
        ORDER BY #{params.sort_by} #{params.sort_order.to_s.upcase}#{null_order}, id #{params.sort_order.to_s.upcase}
        LIMIT #{params.limit}
      SQL
    end

    def job_metadata_merge(id, metadata)
      updated_id = runtime_returning_ids(<<~SQL).first
        UPDATE river_job
        SET metadata = #{runtime_merge_metadata(metadata)}
        WHERE id = #{Integer(id)}
        RETURNING id
      SQL
      updated_id ? job_get_by_id(updated_id) : nil
    end

    def job_rescue_stuck(horizon:, retry_policy:, now: Time.now.utc, max: 1_000)
      transaction do
        # Select only stuck jobs before applying the limit, and hold their locks
        # until rescue finishes so a newer attempt cannot be rescued by mistake.
        lock = runtime_postgres? ? "FOR UPDATE SKIP LOCKED" : ""
        ids = runtime_returning_ids(<<~SQL)
          SELECT id FROM river_job
          WHERE state = 'running' AND attempted_at < #{runtime_time(horizon)}
          ORDER BY id LIMIT #{Integer(max)} #{lock}
        SQL
        jobs = ids.map { |id| job_get_by_id(id) }
        jobs.each do |job|
          cancelled = job.metadata.key?("cancel_attempted_at")
          final = cancelled || job.attempt >= job.max_attempts
          state = if cancelled
            River::JOB_STATE_CANCELLED
          elsif final
            River::JOB_STATE_DISCARDED
          else
            River::JOB_STATE_RETRYABLE
          end
          error = River::AttemptError.new(at: now, attempt: job.attempt, error: "Stuck job rescued by River", trace: "")
          job_set_state_if_running(
            id: job.id,
            error: error,
            finalized_at: final ? now : nil,
            metadata: {"river:rescue_count" => job.metadata.fetch("river:rescue_count", 0).to_i + 1},
            now: now,
            scheduled_at: final ? nil : retry_policy.next_retry(job, error, now: now),
            state: state
          )
        end

        jobs.length
      end
    end

    def job_retry(id, now: Time.now.utc)
      updated_id = runtime_returning_ids(<<~SQL).first
        UPDATE river_job
        SET state = 'available',
            max_attempts = CASE WHEN attempt = max_attempts THEN max_attempts + 1 ELSE max_attempts END,
            finalized_at = NULL,
            scheduled_at = #{runtime_time(now)}
        WHERE id = #{Integer(id)}
          AND state != 'running'
          AND (state != 'available' OR scheduled_at > #{runtime_time(now)})
        RETURNING id
      SQL
      job_get_by_id(updated_id || id)
    end

    def job_schedule(now: Time.now.utc, max: 1_000)
      transaction do
        # Hold each selected row until its transition (including uniqueness
        # conflict handling) finishes. A concurrent retry may change its due time.
        lock = runtime_postgres? ? "FOR UPDATE SKIP LOCKED" : ""
        ids = runtime_query_rows(<<~SQL).map { |row| runtime_value(row, :id).to_i }
          SELECT id FROM river_job
          WHERE state IN ('retryable', 'scheduled') AND scheduled_at <= #{runtime_time(now)}
          ORDER BY priority, scheduled_at, id
          LIMIT #{Integer(max)} #{lock}
        SQL
        ids.each do |id|
          transaction do
            runtime_execute("UPDATE river_job SET state = 'available' WHERE id = #{id} AND state IN ('retryable', 'scheduled')")
          end
        rescue runtime_unique_violation_class
          runtime_execute(<<~SQL)
            UPDATE river_job
            SET state = 'discarded', finalized_at = #{runtime_time(now)},
                metadata = #{runtime_merge_metadata("unique_key_conflict" => "scheduler_discarded")}
            WHERE id = #{id}
          SQL
        end

        ids.length
      end
    end

    def job_set_state_if_running(id:, state:, now: Time.now.utc, attempt: nil,
      error: nil, finalized_at: nil, metadata: nil, scheduled_at: nil)
      state = state.to_s
      retrying = [River::JOB_STATE_AVAILABLE, River::JOB_STATE_RETRYABLE, River::JOB_STATE_SCHEDULED].include?(state)
      cancel_path = retrying ? runtime_cancel_attempted : "false"

      assignments = [] #: Array[String]
      assignments << "attempt = CASE WHEN NOT (#{cancel_path}) THEN #{Integer(attempt)} ELSE attempt END" unless attempt.nil?
      assignments << "errors = #{runtime_append_error(error)}" if error

      assignments << "finalized_at = CASE WHEN #{cancel_path} THEN #{runtime_time(now)} ELSE #{runtime_nullable_time(finalized_at)} END"
      assignments << "metadata = #{runtime_merge_metadata(metadata)}" unless metadata.nil? || metadata.empty?
      assignments << "scheduled_at = CASE WHEN NOT (#{cancel_path}) THEN #{runtime_time(scheduled_at)} ELSE scheduled_at END" if scheduled_at

      assignments << "state = CASE WHEN #{cancel_path} THEN 'cancelled' ELSE #{runtime_state(state)} END"

      id = runtime_returning_ids(<<~SQL).first
        UPDATE river_job
        SET #{assignments.join(",\n    ")}
        WHERE id = #{Integer(id)} AND state = 'running'
        RETURNING id
      SQL
      id ? job_get_by_id(id) : nil
    end

    def job_update(id, params)
      assignments = params.each.map do |field, value|
        raise ArgumentError, "unknown update field: #{field}" unless River::JobUpdateParams.method_defined?(field)

        "#{field} = #{runtime_update_value(field, value)}"
      end

      return job_get_by_id(id) if assignments.empty?

      updated_id = runtime_returning_ids(<<~SQL).first
        UPDATE river_job SET #{assignments.join(", ")}
        WHERE id = #{Integer(id)}
        RETURNING id
      SQL
      updated_id ? job_get_by_id(updated_id) : nil
    end

    def leader_acquire(id, ttl: 30, now: Time.now.utc)
      transaction do
        runtime_execute("DELETE FROM river_leader WHERE expires_at < #{runtime_time(now)}")
        runtime_execute(<<~SQL)
          INSERT INTO river_leader (leader_id, elected_at, expires_at)
          VALUES (#{runtime_quote(id)}, #{runtime_time(now)}, #{runtime_time(now + ttl)})
          ON CONFLICT (name) DO NOTHING
        SQL
        runtime_query_rows("SELECT leader_id FROM river_leader WHERE leader_id = #{runtime_quote(id)}").any?
      end
    end

    def leader_release(id)
      runtime_execute("DELETE FROM river_leader WHERE leader_id = #{runtime_quote(id)}")
    end

    def leader_renew(id, ttl: 30, now: Time.now.utc)
      runtime_query_rows(<<~SQL).any?
        UPDATE river_leader SET expires_at = #{runtime_time(now + ttl)}
        WHERE leader_id = #{runtime_quote(id)} AND expires_at >= #{runtime_time(now)}
        RETURNING leader_id
      SQL
    end

    def queue_get(name)
      row = runtime_query_rows("SELECT #{runtime_queue_columns} FROM river_queue WHERE name = #{runtime_quote(name)}").first
      runtime_queue_from_row(row)
    end

    def queue_list(max: 100)
      runtime_query_rows("SELECT #{runtime_queue_columns} FROM river_queue ORDER BY name LIMIT #{Integer(max)}")
        .map { |row| runtime_queue_from_row(row) }
    end

    def queue_pause(name, now: Time.now.utc)
      filter = (name == "*") ? "true" : "name = #{runtime_quote(name)}"
      runtime_execute(<<~SQL)
        UPDATE river_queue
        SET paused_at = CASE WHEN paused_at IS NULL THEN #{runtime_time(now)} ELSE paused_at END,
            updated_at = CASE WHEN paused_at IS NULL THEN #{runtime_time(now)} ELSE updated_at END
        WHERE #{filter}
      SQL
    end

    def queue_resume(name, now: Time.now.utc)
      filter = (name == "*") ? "true" : "name = #{runtime_quote(name)}"
      runtime_execute(<<~SQL)
        UPDATE river_queue
        SET updated_at = CASE WHEN paused_at IS NOT NULL THEN #{runtime_time(now)} ELSE updated_at END,
            paused_at = NULL
        WHERE #{filter}
      SQL
    end

    def queue_update(name, metadata:, now: Time.now.utc)
      id = runtime_query_rows(<<~SQL).first
        UPDATE river_queue SET metadata = #{runtime_json(metadata)}, updated_at = #{runtime_time(now)}
        WHERE name = #{runtime_quote(name)} RETURNING name
      SQL
      id ? queue_get(name) : nil
    end

    def queue_upsert(name, metadata: {}, now: Time.now.utc)
      runtime_execute(<<~SQL)
        INSERT INTO river_queue (name, created_at, metadata, updated_at)
        VALUES (#{runtime_quote(name)}, #{runtime_time(now)}, #{runtime_json(metadata)}, #{runtime_time(now)})
        ON CONFLICT (name) DO UPDATE SET updated_at = excluded.updated_at
      SQL
      queue_get(name)
    end

    private def runtime_append_error(error)
      value = error.respond_to?(:to_h) ? error.to_h : error
      if runtime_postgres?
        "array_append(errors, #{runtime_json(value)})"
      else
        "jsonb(json_insert(json(coalesce(errors, jsonb('[]'))), '$[#]', json(#{runtime_quote(JSON.dump(value))})))"
      end
    end

    private def runtime_cancel_attempted
      runtime_postgres? ? "metadata ? 'cancel_attempted_at'" : "(metadata -> 'cancel_attempted_at') IS NOT NULL"
    end

    private def runtime_claim_jobs(predicate, max, attempted_by, now)
      transaction do
        attempted_by_sql = if runtime_postgres?
          "array_append(CASE WHEN cardinality(attempted_by) >= 100 THEN attempted_by[(cardinality(attempted_by) - 98):] ELSE attempted_by END, #{runtime_quote(attempted_by)})"
        else
          "jsonb(json_insert(json(coalesce(attempted_by, jsonb('[]'))), '$[#]', #{runtime_quote(attempted_by)}))"
        end

        lock_clause = runtime_postgres? ? "FOR UPDATE SKIP LOCKED" : ""
        ids = runtime_returning_ids(<<~SQL)
          UPDATE river_job
          SET attempt = attempt + 1,
              attempted_at = #{runtime_time(now)},
              attempted_by = #{attempted_by_sql},
              state = 'running'
          WHERE id IN (
            SELECT id FROM river_job
            WHERE #{predicate}
            ORDER BY priority ASC, scheduled_at ASC, id ASC
            LIMIT #{Integer(max)}
            #{lock_clause}
          )
          RETURNING id
        SQL
        ids.map { |id| job_get_by_id(id) }
      end
    end

    private def runtime_in_clause(column, values)
      "#{column} IN (#{values.map { |value| runtime_quote(value) }.join(",")})"
    end

    private def runtime_cursor_clause(params)
      cursor = params.after
      comparison = (params.sort_order == :asc) ? ">" : "<"
      id_clause = "id #{comparison} #{Integer(cursor.id)}"
      return id_clause if params.sort_by == :id

      column = params.sort_by
      return "(#{column} IS NULL AND #{id_clause})" if cursor.value.nil?

      value = runtime_time(cursor.value)
      "(#{column} IS NULL OR #{column} #{comparison} #{value} OR (#{column} = #{value} AND #{id_clause}))"
    end

    private def runtime_json(value)
      encoded = value.is_a?(String) ? value : JSON.dump(value)
      runtime_postgres? ? "#{runtime_quote(encoded)}::jsonb" : "jsonb(#{runtime_quote(encoded)})"
    end

    private def runtime_merge_metadata(metadata)
      if runtime_postgres?
        "metadata || #{runtime_json(metadata)}"
      else
        # PostgreSQL's || replaces top-level values, including JSON null.
        # JSON Merge Patch would recursively merge objects and delete nulls.
        metadata.reduce("metadata") do |expression, (key, value)|
          path = runtime_quote("$.#{JSON.dump(key.to_s)}")
          "jsonb_set(#{expression}, #{path}, jsonb(#{runtime_quote(JSON.dump(value))}))"
        end
      end
    end

    private def runtime_metadata_equals(key, value)
      encoded = runtime_quote(JSON.dump(value))
      if runtime_postgres?
        "metadata -> #{runtime_quote(key.to_s)} = #{encoded}::jsonb"
      else
        # Compare JSON trees so object key order is immaterial, while strings,
        # booleans, null, and missing keys remain distinct. json_each also treats
        # the requested metadata key literally instead of as a JSON path.
        columns = "fullkey, CASE WHEN type IN ('integer', 'real') THEN 'number' ELSE type END, atom"
        actual = <<~SQL
          SELECT #{columns} FROM json_tree(CASE entry.type
            WHEN 'text' THEN json_quote(entry.value)
            WHEN 'null' THEN 'null'
            WHEN 'true' THEN 'true'
            WHEN 'false' THEN 'false'
            ELSE entry.value END)
        SQL
        expected = "SELECT #{columns} FROM json_tree(#{encoded})"
        <<~SQL
          EXISTS (SELECT 1 FROM json_each(metadata) AS entry
            WHERE entry.key = #{runtime_quote(key.to_s)}
              AND NOT EXISTS (#{actual} EXCEPT #{expected})
              AND NOT EXISTS (#{expected} EXCEPT #{actual}))
        SQL
      end
    end

    private def runtime_nullable_time(value)
      value ? runtime_time(value) : "NULL"
    end

    private def runtime_parse_json(value)
      value.is_a?(String) ? JSON.parse(value) : value.to_h
    end

    private def runtime_parse_time(value)
      return nil unless value

      if value.respond_to?(:getutc)
        value.getutc
      else
        Time.parse(value.to_s + (value.to_s.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/) ? "" : " UTC")).utc
      end
    end

    private def runtime_queue_columns
      runtime_postgres? ? "name, created_at, metadata, paused_at, updated_at" : "name, CAST(created_at AS text) AS created_at, json(metadata) AS metadata, CAST(paused_at AS text) AS paused_at, CAST(updated_at AS text) AS updated_at"
    end

    private def runtime_queue_from_row(row)
      return nil unless row

      River::Queue.new(
        runtime_value(row, :name),
        runtime_parse_time(runtime_value(row, :created_at)),
        runtime_parse_json(runtime_value(row, :metadata)),
        runtime_parse_time(runtime_value(row, :paused_at)),
        runtime_parse_time(runtime_value(row, :updated_at))
      )
    end

    private def runtime_returning_ids(sql)
      runtime_query_rows(sql).map { |row| runtime_value(row, :id).to_i }
    end

    private def runtime_state(value)
      runtime_postgres? ? "#{runtime_quote(value)}::river_job_state" : runtime_quote(value)
    end

    private def runtime_tag_contains(tag)
      if runtime_postgres?
        "tags @> ARRAY[#{runtime_quote(tag)}]::varchar[]"
      else
        "EXISTS (SELECT 1 FROM json_each(json(tags)) WHERE value = #{runtime_quote(tag)})"
      end
    end

    private def runtime_time(value)
      raise ArgumentError, "time cannot be nil" unless value

      cast = runtime_postgres? ? "::timestamptz" : ""
      encoded = if runtime_postgres?
        value.getutc.iso8601(6)
      else
        value.getutc.round(3).strftime("%Y-%m-%d %H:%M:%S.%3N")
      end
      "#{runtime_quote(encoded)}#{cast}"
    end

    private def runtime_update_value(field, value)
      case field
      when :attempt, :max_attempts
        Integer(value).to_s
      when :attempted_at, :finalized_at
        value ? runtime_time(value) : "NULL"
      when :attempted_by
        runtime_postgres? ? "ARRAY[#{Array(value).map { |item| runtime_quote(item) }.join(",")}]::text[]" : runtime_json(Array(value))
      when :errors
        input_values = Array(value) #: Array[untyped]
        values = input_values.map { |error| error.respond_to?(:to_h) ? error.to_h : error }
        runtime_postgres? ? "ARRAY[#{values.map { |item| runtime_json(item) }.join(",")}]::jsonb[]" : runtime_json(values)
      when :metadata
        runtime_json(value)
      when :state
        runtime_state(value)
      end
    end
  end
end
