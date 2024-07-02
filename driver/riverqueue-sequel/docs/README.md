#  riverqueue-sequel [![Build Status](https://github.com/riverqueue/riverqueue-ruby-sequel/workflows/CI/badge.svg)](https://github.com/riverqueue/riverqueue-ruby-sequel/actions)

[Sequel](https://github.com/jeremyevans/sequel) driver for [River](https://github.com/riverqueue/river)'s [`riverqueue` gem for Ruby](https://rubygems.org/gems/riverqueue).

`Gemfile` should contain the core gem and a driver like this one:

``` yaml
gem "riverqueue"
gem "riverqueue-sequel"
```

Initialize a client with:

```ruby
DB = Sequel.connect("postgres://...")
client = River::Client.new(River::Driver::Sequel.new(DB))
```

See also [`rubyqueue`](https://github.com/riverqueue/riverqueue-ruby).

## Development

See [development](./development.md).
