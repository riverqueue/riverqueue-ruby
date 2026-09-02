# Schema migrations

River Ruby includes a migration API and the `river` command. Neither needs
Go installed. The gems bundle byte-for-byte copies of the PostgreSQL and SQLite
SQL from Go's River drivers; only the upstream schema template placeholders are
substituted when executing them.

## Command line

Install `riverqueue-sequel` or `riverqueue-activerecord` and the application's
database gem (`pg` or `sqlite3`). The command auto-detects the River driver gem
available in your bundle, preferring Sequel when both are available. This choice
does not need to match your application's driver: both run the same migrations.
Create the database first, then run:

```sh
bundle exec river migrate-status --database-url postgres://localhost/my_app
bundle exec river migrate-up --database-url postgres://localhost/my_app

# SQLite, using Sequel:
bundle exec river migrate-up --database-url sqlite://storage/river.sqlite3
```

`DATABASE_URL` supplies the URL when `--database-url` is omitted. ActiveRecord
uses `sqlite3:` URLs instead of Sequel's `sqlite:` URLs. To target an existing
PostgreSQL schema, pass `--schema jobs`; otherwise the connection's current
schema is used. Schema names must be simple SQL identifiers. SQLite always
uses its main schema.

Up applies all pending versions. `--target N` stops at version N; `--steps N`
limits the number applied. `--dry-run` lists the plan without executing SQL.
Down defaults to one version and requires explicit confirmation:

```sh
bundle exec river migrate-down --database-url postgres://localhost/my_app --dry-run
bundle exec river migrate-down --database-url postgres://localhost/my_app --yes
```

Down migrations can delete jobs and other data. Back up the database and stop
workers first. `--target 0 --yes` removes the complete selected migration line.

## Ruby API

```ruby
driver = River::Driver::Sequel.new(DB)
migrator = River::Migrator.new(driver)

migrator.status # Version/name records with an applied boolean.
migrator.migrate # Up to the newest bundled version.
migrator.migrate(dry_run: true, target: 7)
migrator.migrate(direction: :down) # One version; no interactive confirmation.
```

The API accepts either driver and optionally `schema:` for PostgreSQL. `migrate`
returns the migration records applied (or planned in dry-run mode), with their
version, name, and original up/down SQL. Each version's SQL and history update
commit in their own transaction. A failing version rolls back while earlier
versions remain committed, so rerunning resumes safely. Do not wrap the migrator
in an application transaction: some PostgreSQL changes require a real commit
before the next version can run.

## Go compatibility and Pro

The migrator reads and writes Go's `river_migration` history, including the
legacy pre-version-5 format. Either language can continue from the other's
applied versions. Unknown newer versions and gaps in history cause an error
rather than guessing what SQL to run. It does not baseline an existing schema
that has no River migration history.

Pro SQL is distributed only inside `riverqueue-pro`, not the public core gem.
Migrate main first, then Pro:

```sh
bundle exec river migrate-up --database-url postgres://localhost/my_app
bundle exec river migrate-up --database-url postgres://localhost/my_app --line pro
```

```ruby
require "riverqueue-pro"

River::Migrator.new(driver).migrate
River::Pro::Migrator.new(driver).migrate
```

Remove other migration lines before downgrading main. Run only one migration
process at a time across languages. Ruby migrators take a PostgreSQL advisory
lock per schema; SQLite takes a write lock per version and checks for concurrent
history changes. These are not shared locks with Go's migration runner.

## Updating the bundled SQL

`migration/manifest.json` records the upstream commit and each file's SHA-256.
The Pro gem has its own manifest. Synchronize or verify against local Go checkouts:

```sh
ruby scripts/sync_migrations.rb ../river
make verify
make verify RIVER_PATH=/path/to/river
ruby scripts/sync_migrations.rb --pro ../riverpro
ruby scripts/sync_migrations.rb --check --pro ../riverpro
```

`make verify` defaults to `../river` and checks SQL contents, filenames, the
license, and the manifest's checksums and source revision. CI fetches the public
River repository at that recorded revision and runs the same check; it does not
require a sibling checkout or access to the private Pro repository.

Review the upstream changes and run the complete test matrix before publishing.
Do not edit the copied SQL independently. Upstream changes are bundled in gem
releases; users do not need the Go repositories or network access at runtime.
