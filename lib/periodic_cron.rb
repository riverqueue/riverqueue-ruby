# frozen_string_literal: true

module River
  # A cron schedule for PeriodicJob. Add the optional +fugit+ gem to use it.
  class PeriodicCron
    # Parses a cron expression once. +timezone+ defaults to UTC; use an IANA
    # name such as America/New_York for local calendar schedules. Specify the
    # timezone here, not inside +expression+. Fugit is loaded only on construction.
    def initialize(expression, timezone: "UTC")
      require "fugit"

      raise ArgumentError, "cron expression must be a String" unless expression.is_a?(String)
      raise ArgumentError, "timezone must be a nonempty name without whitespace" unless timezone.is_a?(String) && /\A\S+\z/.match?(timezone)

      @cron = Object.const_get(:Fugit).const_get(:Cron).do_parse("#{expression} #{timezone}")
    end

    # Returns a UTC Time strictly after +time+. Calendar and daylight-saving
    # rules are provided by Fugit; this helper does not enqueue or persist jobs.
    def next(time)
      @cron.next_time(time).to_t.getutc
    end
  end
end
