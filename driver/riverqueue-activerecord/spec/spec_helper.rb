require "active_record"
require "debug"

ActiveRecord::Base.establish_connection(ENV["TEST_DATABASE_URL"] || "postgres://localhost/river_test")

def test_transaction
  ActiveRecord::Base.transaction do
    yield
    raise ActiveRecord::Rollback
  end
end

require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  minimum_coverage line: 100, branch: 100
end

require "riverqueue"
require "riverqueue-activerecord"
