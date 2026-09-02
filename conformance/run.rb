# frozen_string_literal: true

require "digest"
require "json"
require "rbconfig"
require "tmpdir"

root = File.expand_path("..", __dir__)
reference = JSON.parse(File.read(File.join(__dir__, "reference.json")))
source = File.expand_path(ENV.fetch("RIVER_PATH", "../river"), root)
abort "Set RIVER_CONFORMANCE_DATABASE_URL to a disposable PostgreSQL database" unless ENV["RIVER_CONFORMANCE_DATABASE_URL"]

# Register Ruby only in an isolated checkout. The upstream manifest currently
# knows Go, Rust, and JS; no reference tests or expected results are changed.
Dir.mktmpdir("river-ruby-conformance-") do |directory|
  checkout = File.join(directory, "river")
  abort "Could not clone #{source}" unless system("git", "clone", "--quiet", "--shared", "--no-checkout", source, checkout)
  abort "Fetch #{reference.fetch("revision")} into RIVER_PATH first" unless system("git", "-C", checkout, "checkout", "--quiet", "--detach", reference.fetch("revision"))
  fixture = "fixtures/unique_keys.json"
  abort "Unique fixtures differ from the pinned reference" unless Digest::SHA256.file(File.join(__dir__, fixture)).hexdigest == Digest::SHA256.file(File.join(checkout, "conformance", fixture)).hexdigest
  declared = JSON.parse(File.read(File.join(checkout, "conformance/scenarios/insert-only.json"))).fetch("scenarios").map { |scenario| scenario.fetch("name") }
  coverage = JSON.parse(File.read(File.join(__dir__, "scenario-coverage.json"))).fetch("scenarios")
  abort "Scenario coverage is incomplete or stale" unless coverage.keys.sort == declared.sort
  abort "Scenario evidence is missing" unless coverage.values.all? { |paths| !paths.empty? && paths.all? { |path| File.file?(File.join(root, path)) } }
  manifest_path = File.join(checkout, "conformance/manifest.json")
  manifest = JSON.parse(File.read(manifest_path))
  version = Gem::Specification.load(File.join(root, "riverqueue.gemspec")).version.to_s
  manifest.fetch("implementations")["ruby"] = {"package" => "riverqueue", "registry" => "rubygems", "version" => version}
  File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
  environment = {
    "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
    "RIVER_CONFORMANCE_CANDIDATE" => nil,
    "RIVER_CONFORMANCE_CANDIDATE_FILE" => File.join(__dir__, "candidate.json"),
    "RIVER_CONFORMANCE_REQUIRED" => "1",
    "RIVERQUEUE_RUBY_EXECUTABLE" => RbConfig.ruby,
    "RIVERQUEUE_RUBY_ROOT" => root,
    "RIVER_PATH" => checkout
  }
  abort "Adapter tests failed" unless system(environment, RbConfig.ruby, "-S", "rspec", "conformance/spec", chdir: root)
  abort "Insert-only conformance failed" unless system(environment, "make", "test/conformance/insert-only", chdir: checkout)
end
