# River client for Ruby [![Build Status](https://github.com/riverqueue/riverqueue-ruby/workflows/CI/badge.svg)](https://github.com/riverqueue/riverqueue-ruby/actions) [![Gem Version](https://badge.fury.io/rb/riverqueue.svg)](https://badge.fury.io/rb/riverqueue)

An insert-only Ruby client for [River](https://github.com/riverqueue/river) packaged in the [`riverqueue` gem](https://rubygems.org/gems/riverqueue). Allows jobs to be inserted in Ruby and run by a Go worker, but doesn't support working jobs in Ruby.

## Basic usage

Your project's `Gemfile` should contain the `riverqueue` gem and a driver like [`riverqueue-sequel`](https://github.com/riverqueue/riverqueue-ruby/driver/riverqueue-sequel) (see [drivers](#drivers)):

```ruby
gem "riverqueue"
gem "riverqueue-sequel"
```

Initialize a client with:

```ruby
require "riverqueue"
require "riverqueue-activerecord"

DB = Sequel.connect("postgres://...")
client = River::Client.new(River::Driver::ActiveRecord.new)
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

- Respond to `#kind` with a unique string that identifies them in the database, and which a Go worker will recognize.
- Response to `#to_json` with a JSON serialization that'll be parseable as an object in Go.

They may also respond to `#insert_opts` with an instance of `InsertOpts` to define insertion options that'll be used for all jobs of the kind.

## Insertion options

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

## Inserting unique jobs

[Unique jobs](https://riverqueue.com/docs/unique-jobs) are supported through `InsertOpts#unique_opts`, and can be made unique by args, period, queue, and state. If a job matching unique properties is found on insert, the insert is skipped and the existing job returned.

```ruby
insert_res = client.insert(args, insert_opts: River::InsertOpts.new(
  unique_opts: River::UniqueOpts.new(
    by_args: true,
    by_period: 15 * 60,
    by_queue: true,
    by_state: [River::JOB_STATE_AVAILABLE]
  )
)

# contains either a newly inserted job, or an existing one if insertion was skipped
insert_res.job

# true if insertion was skipped
insert_res.unique_skipped_as_duplicated
```

## Inserting jobs in bulk

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
  River::InsertManyParams.new(SimpleArgs.new(job_num: 1), insert_opts: River::InsertOpts.new(max_attempts: 5)),
  River::InsertManyParams.new(SimpleArgs.new(job_num: 2), insert_opts: River::InsertOpts.new(queue: "high_priority"))
])
```

## Inserting in a transaction

No extra code is needed to insert jobs from inside a transaction. Just make sure that one is open from your ORM of choice, call the normal `#insert` or `#insert_many` methods, and insertions will take part in it.

```ruby
ActiveRecord::Base.transaction do
  client.insert(SimpleArgs.new(strings: ["whale", "tiger", "bear"]))
end
```

```ruby
DB.transaction do
  client.insert(SimpleArgs.new(strings: ["whale", "tiger", "bear"]))
end
```

## Inserting with a Ruby hash

`JobArgsHash` can be used to insert with a kind and JSON hash so that it's not necessary to define a class:

```ruby
insert_res = client.insert(River::JobArgsHash.new("hash_kind", {
    job_num: 1
}))
```

## RBS and type checking

The gem [bundles RBS files](https://github.com/riverqueue/riverqueue-ruby/tree/master/sig) containing type annotations for its API to support type checking in Ruby through a tool like [Sorbet](https://sorbet.org/) or [Steep](https://github.com/soutaro/steep).

## Drivers

### ActiveRecord

Use River with [ActiveRecord](https://guides.rubyonrails.org/active_record_basics.html) by putting the `riverqueue-activerecord` driver in your `Gemfile`:

```ruby
gem "riverqueue"
gem "riverqueue-activerecord"
```

Then initialize driver and client:

```ruby
ActiveRecord::Base.establish_connection("postgres://...")
client = River::Client.new(River::Driver::ActiveRecord.new)
```

### Sequel

Use River with [Sequel](https://github.com/jeremyevans/sequel) by putting the `riverqueue-sequel` driver in your `Gemfile`:

```ruby
gem "riverqueue"
gem "riverqueue-sequel"
```

Then initialize driver and client:

```ruby
DB = Sequel.connect("postgres://...")
client = River::Client.new(River::Driver::Sequel.new(DB))
```

## Development

See [development](./development.md).
