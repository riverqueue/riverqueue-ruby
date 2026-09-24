# frozen_string_literal: true

require "active_record"
require "debug"
require_relative "../../../spec/support/river_sqlite_schema_fixture"

PG_AVAILABLE = begin
  ActiveRecord::Base.establish_connection(ENV["TEST_DATABASE_URL"] || "postgres://localhost/river_test")
  ActiveRecord::Base.connection.execute("SELECT 1")
  true
rescue => e
  raise if ENV["CI"] == "true" || ENV["RIVER_REQUIRE_DATABASES"] == "1"

  warn "PostgreSQL not available, skipping PostgreSQL tests: #{e.message}"
  false
end

def test_transaction
  ActiveRecord::Base.transaction do
    # Tests assume an empty jobs table. Delete inside the transaction so a
    # developer's existing test data is restored by the rollback below.
    %w[river_job river_notification river_queue river_leader].each do |table|
      if ActiveRecord::Base.connection.data_source_exists?(table)
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
      end
    end

    yield
    raise ActiveRecord::Rollback
  end
end

def switch_to_sqlite!
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  RiverSQLiteSchemaFixture.load(ActiveRecord::Base.connection.raw_connection)
end

def switch_to_postgres!
  ActiveRecord::Base.establish_connection(ENV["TEST_DATABASE_URL"] || "postgres://localhost/river_test")
end

unless ENV["RIVERQUEUE_ROOT_TEST_SUITE"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
    minimum_coverage branch: 100, line: 100
  end
end

require "riverqueue"
require "riverqueue-activerecord"
