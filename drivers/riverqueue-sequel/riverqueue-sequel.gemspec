Gem::Specification.new do |s|
  s.name = "riverqueue-sequel"
  s.version = "0.4.0"
  s.summary = "Sequel driver for the River Ruby gem."
  s.description = "Sequel driver for the River Ruby gem. Use in conjunction with the riverqueue gem to insert jobs that are worked in Go."
  s.authors = ["Blake Gentry", "Brandur Leach"]
  s.email = "brandur@brandur.org"
  s.files = ["lib/riverqueue-sequel.rb"]
  s.homepage = "https://riverqueue.com"
  s.license = "LGPL-3.0-or-later"

  # The stupid version bounds are used to silence Ruby's extremely obnoxious warnings.
  s.add_dependency "pg", "> 0", "< 1000"
  s.add_dependency "sequel", "> 0", "< 1000"
end
