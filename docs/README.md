# River client for Ruby [![Build Status](https://github.com/riverqueue/riverqueue-ruby/workflows/CI/badge.svg)](https://github.com/riverqueue/riverqueue-ruby/actions) [![Gem Version](https://badge.fury.io/rb/riverqueue.svg)](https://badge.fury.io/rb/riverqueue)

A Ruby client for [River](https://github.com/riverqueue/river), packaged in the [`riverqueue` gem](https://rubygems.org/gems/riverqueue). It inserts and works jobs using River's canonical database schema and state machine, so Ruby and Go clients can safely share a River database. Separate queues are recommended when each language recognizes different job kinds.

## Installation

Moving an existing application? See [Migrating from Sidekiq](migrating_from_sidekiq.md).

Add one River driver and only the database adapter your application uses. The driver brings in `riverqueue`:

```ruby
# Sequel
gem "riverqueue-sequel"
gem "pg" # or: gem "sqlite3"

# Active Record
gem "riverqueue-activerecord"
gem "pg" # or: gem "sqlite3"
```

Apply River's canonical migrations before using the client. See [Schema and migrations](#schema-and-migrations).

## Basic usage

Define JSON-serializable job arguments and a worker with the same `kind`, register the worker on a queue, and start the client:

```ruby
require "riverqueue-sequel"

class SortArgs
  attr_reader :strings

  def initialize(strings:)
    @strings = strings
  end

  def kind = "sort"
  def to_json = JSON.dump(strings: strings)
end

class SortWorker
  def self.kind = "sort"

  def work(job)
    job.output = {strings: job.args.fetch("strings").sort}
  end
end

client = River::Client.new(
  River::Driver::Sequel.new(DB),
  config: River::Config.new(
    queues: {ruby: 10},
    workers: River::Workers.new.add(SortWorker)
  )
).start

result = client.insert(
  SortArgs.new(strings: %w[whale tiger bear]),
  insert_opts: River::InsertOpts.new(queue: :ruby)
)
result.job # River::JobRow

client.stop
```

Job arguments must respond to `#kind` and `#to_json`. They may also return default options from `#insert_opts`; options passed directly to `#insert` take precedence. Workers receive a `River::Job`, which delegates persisted attributes like `id`, `args`, `attempt`, and `metadata` to its `River::JobRow`.

Use strings for `#kind` definitions, and symbols for identifiers such as queues,
states, periodic job IDs, and resumable step names. Both forms are accepted.
Persisted job attributes and JSON object keys remain strings, preserving
compatibility with Go clients.
Examples omit parentheses on simple calls and `do...end` blocks, retaining them
for nested expressions and `{ ... }` blocks where they make binding clear.

## Core features

### [Accessing the client from workers](https://riverqueue.com/docs/context-client)

Every running `River::Job` exposes the client that claimed it. Workers can use
`job.client` to insert follow-up work or call other client APIs without relying
on a global:

```ruby
def work(job)
  result = process(job.args)
  job.client.insert NotifyArgs.new(result_id: result.id)
end
```

### [Job insertion and options](https://riverqueue.com/docs/inserting-and-working-jobs)

`River::InsertOpts` controls the queue, priority, maximum attempts, schedule, tags, metadata, and uniqueness of a job. Priority `1` is highest.

```ruby
result = client.insert(args, insert_opts: River::InsertOpts.new(
  max_attempts: 10,
  metadata: {trace_id: trace_id},
  priority: 1,
  queue: :critical,
  tags: %w[billing customer-42]
))
```

For simple jobs, `River::JobArgsHash.new(:kind, hash)` avoids defining an argument class.

### [Transactional enqueueing](https://riverqueue.com/docs/transactional-enqueueing)

Inserts automatically join a transaction opened through the same Active Record connection or Sequel database object. A rollback also rolls back the job:

The ActiveRecord driver defaults to `ActiveRecord::Base`. Use
`River::Driver::ActiveRecord.new(connection_class: ApplicationRecord)` to select
an abstract connection class. Queries, inserts, transactions, runtime operations,
and migrations all use its pool. Each driver has an isolated internal model and
does not inherit application scopes or callbacks. Transactions on a different
connection do not roll back River inserts.

```ruby
DB.transaction do
  save_order
  client.insert FulfillOrderArgs.new(order_id: order.id)
end
```

The equivalent works inside `ActiveRecord::Base.transaction` with the Active Record driver.

### [Bulk insertion](https://riverqueue.com/docs/inserting-many-jobs)

`#insert_many` inserts a batch atomically and returns one `River::JobInsertResult` per input. Use `River::InsertManyParams` when jobs need different options:

```ruby
results = client.insert_many([
  SortArgs.new(strings: %w[c b a]),
  River::InsertManyParams.new(
    SortArgs.new(strings: %w[z y x]),
    insert_opts: River::InsertOpts.new(queue: :bulk)
  )
])
```

### [Scheduled jobs](https://riverqueue.com/docs/scheduled-jobs)

Set `scheduled_at` to keep a job from becoming available before a future UTC time. River's maintenance leader promotes it when due:

```ruby
client.insert(args, insert_opts: River::InsertOpts.new(
  scheduled_at: Time.now.utc + 3600
))
```

### [Unique jobs](https://riverqueue.com/docs/unique-jobs)

`River::UniqueOpts` can make a kind unique by all or selected arguments, time period, queue, and state. A conflict returns the existing job with `unique_skipped_as_duplicated == true`.

```ruby
result = client.insert(args, insert_opts: River::InsertOpts.new(
  unique_opts: River::UniqueOpts.new(
    by_args: [:account_id],
    by_period: 15 * 60,
    by_queue: true
  )
))
```

Custom `by_state` sets must contain `:available`, `:pending`, `:running`, and `:scheduled`. Set `exclude_kind: true` to enforce the same key across multiple job kinds.

### [Reliable execution and stuck jobs](https://riverqueue.com/docs/reliable-workers)

Claims and state transitions are atomic in the database. If a process disappears while working, the elected maintenance client rescues stale running jobs after an hour, retrying or discarding them according to their attempt count. `attempted_by`, attempt errors, and final state remain in the canonical River row for inspection by Ruby, Go, or River UI.

### [Job retries](https://riverqueue.com/docs/job-retries)

An exception normally moves a job to `retryable`; exhausting `max_attempts` moves it to `discarded`. Workers may choose an absolute retry time, or a client-wide policy may calculate it:

```ruby
class APIWorker
  def self.kind = "api"
  def work(job) = call_api(job.args)
  def next_retry(_job, _error) = Time.now.utc + 30
end

config = River::Config.new(
  retry_policy: MyRetryPolicy.new # responds to next_retry(job, error, now:)
)
```

Use `client.job_retry(job_id)` to make a non-running job available immediately.

A worker may implement `retry?(job, error)` and return false to discard a
reported error immediately, without reducing the attempt budget used for crash
recovery. The Rails integration uses this to let Active Job own application retries.
If a retry hook or policy raises, River logs the callback error and falls back to
retrying with the default backoff. The original work error is still recorded.

### [Error handling and timeouts](https://riverqueue.com/docs/error-handling)

Errors are recorded on the job with their attempt, message, timestamp, and trace. `error_handler` may return `:cancel` or `true` to cancel instead of retrying. `job_timeout` defaults to 60 seconds; a worker-specific `timeout(job)` may override it, return `nil` to disable it, or return `0` to use the client default.

```ruby
config = River::Config.new(
  error_handler: ->(error, _job) { :cancel if error.is_a?(PermanentError) },
  job_timeout: 30
)
```

### [Cancelling jobs](https://riverqueue.com/docs/cancelling-jobs)

Cancel a job externally with `client.job_cancel(id)`. Available jobs finalize immediately; running workers are interrupted after the runtime observes the cancellation marker. A worker can cancel itself by raising the error returned from `River.job_cancel`.

```ruby
client.job_cancel job_id

def work(job)
  raise River.job_cancel("account closed") if account_closed?(job)
end
```

`River.job_cancel` also accepts an exception, which is retained as the
`River::JobCancelError` cause. The error class is public for rescue clauses and
test assertions.

### [Snoozing jobs](https://riverqueue.com/docs/snoozing-jobs)

Raise the error returned by `River.job_snooze` to reschedule without consuming an attempt. Short snoozes become immediately fetchable after their delay; longer ones are promoted by maintenance. `River::JobSnoozeError` remains public for rescue clauses and test assertions.

```ruby
def work(job)
  raise River.job_snooze(30) unless dependency_ready?(job)
end
```

### [Multiple queues](https://riverqueue.com/docs/multiple-queues)

Queues isolate throughput and set independent thread concurrency. Each queue has a producer thread, and claimed jobs run in worker threads up to `max_workers`.

```ruby
config = River::Config.new(queues: {
  bulk: River::QueueConfig.new(
    fetch_cooldown: 0.2,
    fetch_poll_interval: 1.0,
    max_workers: 4
  ),
  critical: River::QueueConfig.new(max_workers: 20)
})
```

Queues may also be added and removed at runtime with `client.queue_add(name, config)` and `client.queue_remove(name)`.

### [Pausing queues](https://riverqueue.com/docs/pausing-queues)

Pausing is persisted, so every client sharing the database observes it. Pass `"*"` to affect all queues.

```ruby
client.queue_pause :bulk
client.queue_resume :bulk

client.queue_pause "*"
client.queue_resume "*"
```

Use `queue_get`, `queue_list`, and `queue_update` to inspect queues and attach metadata.

### Rails and Active Job

Install the separate `riverqueue-rails` gem for `config.active_job.queue_adapter = :river`,
Active Job/Action Mailer execution, Rails context handling, and `bin/jobs start`.
See the [Rails integration guide](../rails/riverqueue-rails/README.md) for setup,
transactional enqueueing, retry semantics, and supported Rails versions.

### [Periodic jobs](https://riverqueue.com/docs/periodic-jobs)

Register a schedule and a constructor that returns job arguments, `[arguments, insert_options]`, or `nil` to skip that run. Core periodic schedules live in the client process; River Pro adds durable schedules.

```ruby
cleanup = River::PeriodicJob.new(
  id: :cleanup,
  constructor: -> { [CleanupArgs.new, River::InsertOpts.new(queue: :maintenance)] },
  run_on_start: true,
  schedule: River::PeriodicInterval.new(3600)
)

config = River::Config.new(periodic_jobs: [cleanup])
handle = client.periodic_jobs.add(another_periodic_job)
client.periodic_jobs.remove handle
```

`client.periodic_jobs` returns a `River::PeriodicJobBundle`, matching River's
Go API.

Schedules can be callbacks (`schedule: ->(now) { now + 300 }`) or objects
implementing `next(time)`. They compute the next occurrence after the supplied
time; they do not execute the job themselves.

For calendar schedules, add `gem "fugit", "~> 1.13"` to your Gemfile:

```ruby
cleanup = River::PeriodicJob.new(
  id: :weekday_cleanup,
  constructor: -> { CleanupArgs.new },
  schedule: River::PeriodicCron.new("0 9 * * 1-5", timezone: "America/New_York")
)
```

`PeriodicCron` parses once and loads Fugit only when constructed. Fugit is not
a runtime dependency of the River gem. The timezone defaults explicitly to UTC;
provide it through `timezone:`, not inside the expression. Five-field cron,
optional seconds, and aliases such as `@daily` use Fugit's syntax. Results are
UTC `Time` objects. Local calendar times follow Fugit's daylight-saving rules;
nonexistent spring-forward times are skipped. Test ambiguous fall-back times
for your schedules. Cron does not change core scheduling durability or replay
missed occurrences after downtime.

For a one-time date, insert a job with
`InsertOpts.new(scheduled_at: Time.utc(2026, 9, 20, 9))` instead of registering
a periodic job. This stores the scheduled job immediately in the database.

### [Resumable jobs](https://riverqueue.com/docs/resumable-jobs)

Long jobs can checkpoint idempotent steps and cursor progress. On retry, River skips completed steps and resumes a cursor step from its last recorded value using the same metadata format as Go.

```ruby
def work(job)
  job.resumable_step :download do
    download(job.args)
  end

  job.resumable_step_cursor :rows, default: 0 do |last_row|
    import_rows(after: last_row) do |row|
      job.resumable_set_cursor row.id
    end
  end
end
```

`job.resumable_checkpoint(cursor: value)` writes a checkpoint immediately. Omit `cursor:` to checkpoint the current step with any cursor already recorded. Wrap it and related application writes in `client.driver.transaction` when they must commit atomically.

### [Recorded output and metadata](https://riverqueue.com/docs/recorded-output)

Assign `job.output` to store JSON-compatible output under `metadata["output"]`. Use `job.update_metadata` for other metadata that should be committed with the attempt's final transition.

```ruby
def work(job)
  job.update_metadata provider_request_id: request_id
  job.output = {imported: 42}
end
```

### Plugins

Plugins provide one ordered configuration point for lifecycle callbacks and
wrapping middleware. These are two distinct extension styles even though both
are registered through `Config#plugins`:

- A **hook** runs at one specific lifecycle point and then returns. Hooks are
  appropriate for observing or making a small change at that point.
- **Middleware** wraps a complete insertion or work operation. It can run code
  before and after the inner operation, and must call `operation.call` to let
  that operation continue.

A plugin may implement any combination of these methods:

| Style      | Method                           | When it runs                                                                                 |
| ---------- | -------------------------------- | -------------------------------------------------------------------------------------------- |
| Hook       | `insert_begin(params)`           | Before each job is inserted; `params` may be modified.                                       |
| Hook       | `insert_end(result)`             | After each job is inserted.                                                                  |
| Hook       | `work_begin(job)`                | After a job is claimed, immediately before its worker runs.                                  |
| Hook       | `work_end(job, error)`           | After the worker returns or raises; `error` is `nil` on success.                             |
| Hook       | `job_finalize(job, state)`       | Before successful finalization; returning `:delete` deletes the job instead of retaining it. |
| Middleware | `insert_many(params, operation)` | Around one insertion call; `params` is an array even for `Client#insert`.                    |
| Middleware | `work(job, operation)`           | Around the work hooks and worker for one claimed job.                                        |

A single plugin can provide both styles. For example, it might use
`insert_begin` to add metadata and `work` to time the complete work operation.

```ruby
class TimingPlugin
  def work(job, operation)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    operation.call
  ensure
    Metrics.observe(
      job.kind,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    )
  end
end

config = River::Config.new(plugins: [AuditPlugin.new, TimingPlugin.new])
```

Plugins earlier in the list are the outermost wrappers. Begin callbacks run in
configuration order, while `insert_end` callbacks run in reverse order. In
effect, work execution is nested as: middleware before, `work_begin`, worker,
`work_end`, middleware after.

### [Subscriptions](https://riverqueue.com/docs/subscriptions)

Subscribe to job and queue events for logging or metrics. Subscriptions are
bounded and drop new events rather than blocking workers when their buffer is
full. `subscription.close` unregisters it from the client and wakes waiting
readers; closing more than once is safe. Buffered events remain readable, then
`each` ends and blocking `pop` calls return `nil`. Non-blocking `pop(true)` raises
`ThreadError` whenever no event is available, including after closure.

```ruby
subscription = client.subscribe(
  :job_completed,
  :job_failed,
  buffer_size: 1_000
)

subscription.each { |event| consume(event) }
subscription.close
```

Events include completed, failed, cancelled, snoozed, and interrupted jobs, plus paused and resumed queues.

### Job administration

The client can fetch, filter, update, cancel, retry, and delete jobs. Lists return
a `JobListCursor` in `last_cursor`. Pass it as `after`, preserving the same filters
and ordering, to fetch the next page. Cursors retain both the sort value and ID,
so timestamp ordering handles ties and continues working if the cursor job is
deleted. Null timestamps sort last in either direction. For ID ordering only,
`after_id` is also available as a shortcut with an integer ID.

```ruby
list_options = {
  limit: 100,
  queues: [:bulk],
  sort_by: :scheduled_at,
  states: [:discarded],
  tags_any: ["billing"]
}
page = client.job_list(River::JobListParams.new(**list_options))

next_page = client.job_list(River::JobListParams.new(**list_options, after: page.last_cursor))
client.job_update job_id, River::JobUpdateParams.new(max_attempts: 50)
client.job_delete_many River::JobListParams.new(states: [:cancelled])
```

Bulk deletion requires at least one filter and never deletes running jobs.
Metadata filters compare complete JSON values at each supplied top-level key,
including nested objects and arrays. Numbers, strings, and booleans remain
distinct; a null value matches a present JSON null, not a missing key.

### [Leader election](https://riverqueue.com/docs/leader-election)

Running clients coordinate through the canonical `river_leader` table. Only the
current leader performs database-wide scheduling, stuck-job rescue, retention,
and custom maintenance, and another client can take over after its lease
expires.

### [Maintenance services and retention](https://riverqueue.com/docs/maintenance-services)

The maintenance leader promotes scheduled jobs, rescues stuck work, deletes
finalized rows, and runs custom services. Retention is configured in seconds;
use `nil` or `-1` to retain a state indefinitely.

```ruby
config = River::Config.new(
  cancelled_job_retention_period: 86_400,
  completed_job_retention_period: 86_400,
  discarded_job_retention_period: 7 * 86_400,
  maintenance_services: [MyMaintenanceService.new]
)
```

A custom service implements `run(client, driver, now)` and runs only while this client holds leadership.

### [Renaming job kinds](https://riverqueue.com/docs/renaming-jobs)

Register old names as aliases while producers migrate to a new kind. All aliases resolve to the same worker:

```ruby
workers = River::Workers.new.add(NewReportWorker, aliases: [:old_report])
```

Keep aliases registered until no jobs with the old kind remain.

### [Stopping gracefully](https://riverqueue.com/docs/graceful-shutdown)

For a dedicated foreground worker process with application boot and signal
handling, use the [worker command](./workers.md):

```sh
bundle exec river worker --config config/river.rb --stop-timeout 30
# Rails, from the application root:
RAILS_ENV=production bundle exec river worker --rails
```

The Ruby configuration file must return an unstarted client. The following client
methods are for applications managing their own runtime lifecycle:

`client.stop` stops fetching and waits for active jobs to finish. `client.stop_and_cancel` interrupts active worker threads and returns their jobs to `available` without consuming the interrupted attempt.

Use `client.stop(wait: false)` to request stop and return immediately without
interrupting active workers. Call `client.stop` later to wait for draining and
finish cleanup. Until that waiting call completes, `started?` remains true and
`stopped?` remains false. In-flight fetches or maintenance operations may finish.

### [Insert-only clients](https://riverqueue.com/docs/insert-only-clients)

A client with no configured queues can insert and administer jobs without starting worker or maintenance threads:

```ruby
client = River::Client.new(driver, config: River::Config.new(queues: {}))
client.insert args
```

## Schema and migrations

`River::Migrator` and the bundled `river` command run exact copies of Go's
canonical migrations for PostgreSQL and SQLite. No Go installation is needed:

```sh
bundle exec river migrate-up --database-url postgres://localhost/my_app
```

The command auto-detects `riverqueue-sequel` or `riverqueue-activerecord` from
the available gems, preferring Sequel when both are in your bundle.
For the API, status, dry runs, downgrades, and schema options, see
[migrations](migrations.md). Test schema snapshots under `spec/support` remain
test-only and must not be used to provision production databases.

For River Pro, apply both the canonical `main` and `pro` migration lines. Ruby and Go clients use the same tables, columns, indexes, generated columns, and triggers.

## Threads and Ractors

Queue producers, maintenance, and jobs run in threads. River's public constants are Ractor-shareable, but clients, database pools, and drivers should not currently be shared between Ractors. We're keeping an eye on evolving Ractor support in database drivers, Active Record, and Sequel, and hope to be able to provide best-in-class support for them once it's more feasible to do so.

## RBS and type checking

The gem bundles [RBS files](https://github.com/riverqueue/riverqueue-ruby/tree/master/sig) for tools such as [Steep](https://github.com/soutaro/steep) and other RBS-compatible type checkers.

## Drivers

### Active Record

```ruby
require "riverqueue-activerecord"

ActiveRecord::Base.establish_connection("postgres://...")
client = River::Client.new(River::Driver::ActiveRecord.new)
```

### Sequel

```ruby
require "riverqueue-sequel"

DB = Sequel.connect("postgres://...")
client = River::Client.new(River::Driver::Sequel.new(DB))
```

Neither driver installs `pg` or `sqlite3`; the application chooses its adapter.

### Redis (experimental)

Add `riverqueue-redis` to use Redis 7+ without either SQL adapter:

```ruby
require "riverqueue-redis"

pool = RedisClient.config(url: ENV.fetch("REDIS_URL")).new_pool(size: 10)
client = River::Client.new(
  River::Driver::Redis.new(pool, prefix: "my_app", schema: "shared"),
  config: River::Config.new(
    queues: {ruby: 10},
    workers: River::Workers.new.add(SortWorker)
  )
).start
```

Ruby and Go's experimental `riverredisv9` driver can share the same namespace,
using identical job records, indexes, and ID allocation. Stop the client before
closing the pool. No migrations are needed. Redis-only transactions cannot be
atomic with application SQL writes; Rails integration and Pro's SQL-backed
features are not supported. See the [Redis driver guide](../driver/riverqueue-redis/README.md)
for durability requirements, compatibility, and other experimental limitations.

## Testing

For database-backed insertion assertions and synchronous worker tests, see
[Testing River jobs](./testing.md). Helpers ship in the core gem; RSpec and
Minitest integrations are optional and explicitly loaded.

## River Pro

River Pro is kept in the separate, privately distributed `riverqueue-pro` gem, so possession of that package is the access boundary. It is not included in the MPL-2.0 core gem. See the [River Pro Ruby documentation](../pro/riverqueue-pro/README.md) for configuration and feature examples.

## Current differences from the Go client

The Ruby client does not currently provide dedicated OpenTelemetry/metrics
integrations, job-persisted logging, or
transactional job completion alongside application writes. Plugins and
subscriptions provide integration points for telemetry. Job execution uses Ruby
worker objects rather than Go's work-function API.

## Development

See [development](./development.md).
