require "sequel"
require_relative "../../../spec/support/river_sqlite_schema_fixture"

DB = begin
  Sequel.connect(ENV["TEST_DATABASE_URL"] || "postgres://localhost/river_test")
rescue => e
  warn "PostgreSQL not available, skipping PostgreSQL tests: #{e.message}"
  nil
end

SQLITE_DB = begin
  require "sqlite3"
  Sequel.sqlite.tap do |db|
    db.synchronize { |connection| RiverSQLiteSchemaFixture.load(connection) }
  end
rescue LoadError
  warn "sqlite3 gem not available, skipping SQLite tests"
  nil
end

def test_transaction
  DB.transaction do
    yield
    raise Sequel::Rollback
  end
end

def sqlite_test_transaction
  SQLITE_DB.transaction do
    yield
    raise Sequel::Rollback
  end
end

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  minimum_coverage line: 100, branch: 100
end

require "riverqueue"
require "riverqueue-sequel"
