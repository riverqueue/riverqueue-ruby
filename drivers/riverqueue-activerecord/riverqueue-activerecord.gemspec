Gem::Specification.new do |s|
  s.name = "riverqueue-activerecord"
  s.version = "0.2.0"
  s.summary = "ActiveRecord driver for the River Ruby gem."
  s.description = "ActiveRecord driver for the River Ruby gem. Use in conjunction with the riverqueue gem to insert jobs that are worked in Go."
  s.authors = ["Blake Gentry", "Brandur Leach"]
  s.email = "brandur@brandur.org"
  s.files = ["lib/riverqueue-activerecord.rb"]
  s.homepage = "https://riverqueue.com"
  s.license = "LGPL-3.0-or-later"

  # The stupid version bounds are used to silence Ruby's extremely obnoxious warnings.
  s.add_dependency "activerecord", "> 0", "< 1000"
  s.add_dependency "activesupport", "> 0", "< 1000" # required for ActiveRecord to load properly
  s.add_dependency "pg", "> 0", "< 1000"
end
