require "active_record"
require "debug"
require_relative "../../../spec/support/river_sqlite_schema_fixture"

PG_AVAILABLE = begin
  ActiveRecord::Base.establish_connection(ENV["TEST_DATABASE_URL"] || "postgres://localhost/river_test")
  ActiveRecord::Base.connection.execute("SELECT 1")
  true
rescue => e
  warn "PostgreSQL not available, skipping PostgreSQL tests: #{e.message}"
  false
end

def test_transaction
  ActiveRecord::Base.transaction do
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

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  minimum_coverage line: 100, branch: 100
end

require "riverqueue"
require "riverqueue-activerecord"
