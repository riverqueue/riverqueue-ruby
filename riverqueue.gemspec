Gem::Specification.new do |s|
  s.name = "riverqueue"
  s.version = "0.8.0"
  s.summary = "River is a fast job queue for Go."
  s.description = "River is a fast job queue for Go. Use this gem in conjunction with gems riverqueue-activerecord or riverqueue-sequel to insert jobs in Ruby which will be worked from Go."
  s.authors = ["Blake Gentry", "Brandur Leach"]
  s.email = "brandur@brandur.org"
  s.files = Dir.glob("lib/**/*")
  s.homepage = "https://riverqueue.com"
  s.license = "LGPL-3.0-or-later"
  s.require_path = %(lib)
  s.metadata = {
    "bug_tracker_uri" => "https://github.com/riverqueue/riverqueue-ruby/issues",
    "changelog_uri" => "https://github.com/riverqueue/riverqueue-ruby/blob/master/CHANGELOG.md",
    "rubygems_mfa_required" => "true",
    "source_code_uri" => "https://github.com/riverqueue/riverqueue-ruby"
  }
end
