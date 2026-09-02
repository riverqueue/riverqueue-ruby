# frozen_string_literal: true

require "sequel"
require_relative "../../../spec/support/river_sqlite_schema_fixture"

DB = begin
  Sequel.connect(ENV["TEST_DATABASE_URL"] || "postgres://localhost/river_test")
rescue => e
  raise if ENV["CI"] == "true" || ENV["RIVER_REQUIRE_DATABASES"] == "1"

  warn "PostgreSQL not available, skipping PostgreSQL tests: #{e.message}"
  nil
end

SQLITE_DB = begin
  require "sqlite3"
  Sequel.sqlite.tap do |db|
    db.synchronize { |connection| RiverSQLiteSchemaFixture.load(connection) }
  end
rescue LoadError
  raise if ENV["CI"] == "true" || ENV["RIVER_REQUIRE_DATABASES"] == "1"

  warn "sqlite3 gem not available, skipping SQLite tests"
  nil
end

def test_transaction
  DB.transaction do
    # Tests assume an empty jobs table. Delete inside the transaction so a
    # developer's existing test data is restored by the rollback below.
    [:river_job, :river_notification, :river_queue, :river_leader].each do |table|
      DB[table].delete if DB.table_exists?(table)
    end

    yield
    raise Sequel::Rollback
  end
end

def sqlite_test_transaction
  SQLITE_DB.transaction do
    [:river_job, :river_notification, :river_queue, :river_leader].each { |table| SQLITE_DB[table].delete }
    yield
    raise Sequel::Rollback
  end
end

def available_test_database
  DB || SQLITE_DB
end

def available_test_transaction(&)
  if DB
    test_transaction(&)
  elsif SQLITE_DB
    sqlite_test_transaction(&)
  else
    skip "PostgreSQL and SQLite are unavailable"
  end
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
require "riverqueue-sequel"
