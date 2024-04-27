# River client for Ruby [![Build Status](https://github.com/riverqueue/riverqueue-ruby/workflows/CI/badge.svg)](https://github.com/riverqueue/riverqueue-ruby/actions)

An insert-only Ruby client for [River](https://github.com/riverqueue/river) packaged in the [`riverqueue` gem](https://rubygems.org/gems/riverqueue). Allows jobs to be inserted in Ruby and run by a Go worker, but doesn't support working jobs in Ruby.

## Basic usage

`Gemfile` should contain the core gem and a driver like [`rubyqueue-sequel`](https://github.com/riverqueue/riverqueue-ruby/drivers/riverqueue-sequel) (see [drivers](#drivers)):

``` ruby
gem "riverqueue"
gem "riverqueue-sequel"
```

Initialize a client with:

```ruby
DB = Sequel.connect("postgres://...")
client = River::Client.new(River::Driver::Sequel.new(DB))
```

Define a job and insert it:

```ruby
class SortArgs
  attr_accessor :strings

  def initialize(strings:)
    self.strings = strings
  end

  def kind = "sort"

  def to_json = JSON.dump({strings: strings})
end

insert_res = client.insert(SimpleArgs.new(strings: ["whale", "tiger", "bear"]))
insert_res.job # inserted job row
```

Job args should:

* Respond to `#kind` with a unique string that identifies them in the database, and which a Go worker will recognize.
* Response to `#to_json` with a JSON serialization that'll be parseable as an object in Go.

They may also respond to `#insert_opts` with an instance of `InsertOpts` to define insertion options that'll be used for all jobs of the kind.

### Insertion options

Inserts take an `insert_opts` parameter to customize features of the inserted job:

```ruby
insert_res = client.insert(
  SimpleArgs.new(strings: ["whale", "tiger", "bear"]),
  insert_opts: River::InsertOpts.new(
    max_attempts: 17,
    priority: 3,
    queue: "my_queue",
    tags: ["custom"]
  )
)
```

### Inserting with a Ruby hash

`JobArgsHash` can be used to insert with a kind and JSON hash so that it's not necessary to define a class:

```ruby
insert_res = client.insert(River::JobArgsHash.new("hash_kind", {
    job_num: 1
}))
```

### Bulk inserting jobs

Use `#insert_many` to bulk insert jobs as a single operation for improved efficiency:

```ruby
num_inserted = client.insert_many([
  SimpleArgs.new(job_num: 1),
  SimpleArgs.new(job_num: 2)
])
```

Or with `InsertManyParams`, which may include insertion options:

```ruby
num_inserted = client.insert_many([
  River::InsertManyParams.new(SimpleArgs.new(job_num: 1), insert_opts: InsertOpts.new(max_attempts: 5)),
  River::InsertManyParams.new(SimpleArgs.new(job_num: 2), insert_opts: InsertOpts.new(queue: "high_priority"))
])
```

## Drivers

### ActiveRecord

``` ruby
gem "riverqueue"
gem "riverqueue-activerecord"
```

Initialize driver and client:

```ruby
ActiveRecord::Base.establish_connection("postgres://...")
client = River::Client.new(River::Driver::ActiveRecord.new)
```

### Sequel

``` ruby
gem "riverqueue"
gem "riverqueue-sequel"
```

Initialize driver and client:

```ruby
DB = Sequel.connect("postgres://...")
client = River::Client.new(River::Driver::Sequel.new(DB))
```

## Development

See [development](./development.md).