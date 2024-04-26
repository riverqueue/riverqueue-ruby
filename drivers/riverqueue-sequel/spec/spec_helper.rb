require "sequel"

DB = Sequel.connect(ENV["TEST_DATABASE_URL"] || "postgres://localhost/riverqueue_ruby_test")

def test_transaction
  DB.transaction do
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
