# riverqueue-sequel

[Sequel](https://sequel.jeremyevans.net/) driver for [River](https://github.com/riverqueue/river)'s [`riverqueue` gem for Ruby](https://rubygems.org/gems/riverqueue). PostgreSQL and SQLite are supported.

Add the core gem and this driver to `Gemfile`:

```ruby
gem "riverqueue"
gem "riverqueue-sequel"
```

Database adapters are optional dependencies. Add only the adapter used by your
application.

For PostgreSQL, add `pg` to `Gemfile`:

```ruby
gem "pg"
```

Then initialize a client with a Sequel database:

```ruby
db = Sequel.connect("postgres://localhost/my_app")
client = River::Client.new(River::Driver::Sequel.new(db))
```

For SQLite, add `sqlite3` to `Gemfile`:

```ruby
gem "sqlite3"
```

Then initialize a client with an SQLite database:

```ruby
db = Sequel.connect("sqlite://storage/river.sqlite3", timeout: 5_000)
client = River::Client.new(River::Driver::Sequel.new(db))
```

Use current River migrations to create and update the SQLite database.

## Development

See [development](./development.md).
