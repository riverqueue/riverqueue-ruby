require "debug"

# Only show coverage information if running the entire suite.
if RSpec.configuration.files_to_run.length > 1
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    minimum_coverage line: 100, branch: 100
  end
end

require "riverqueue"
