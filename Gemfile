source "https://rubygems.org"

gemspec

group :development, :test do
  # both gems temporarily pointed to master to get Ruby 4.0 support
  #gem "ffi", git: "https://github.com/ffi/ffi", submodules: true
  #gem "pg", git: "https://github.com/ged/ruby-pg", force_ruby_platform: true

  gem "standard"
  gem "steep"
end

group :test do
  gem "debug"
  gem "rspec-core"
  gem "rspec-expectations"
  gem "riverqueue-sequel", path: "driver/riverqueue-sequel"
  gem "simplecov", require: false
end
