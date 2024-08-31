require "debug"

# Only show coverage information if running the entire suite.
if RSpec.configuration.files_to_run.length > 1
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100

    # Drivers have their own spec suite where they're covered 100.0%, but
    # they're not fully covered from this top level test suite.
    add_filter("driver/riverqueue-sequel/")
  end
end

require "riverqueue"
