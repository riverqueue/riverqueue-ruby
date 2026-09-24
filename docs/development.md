# riverqueue-ruby development

## Install dependencies

```shell
$ bundle install
$ pushd driver/riverqueue-activerecord && bundle install && popd
$ pushd driver/riverqueue-sequel && bundle install && popd
$ pushd rails/riverqueue-rails && bundle install && popd
$ pushd pro/riverqueue-pro && bundle install && popd
```

Keep the root lockfile usable on both macOS and Linux when updating dependencies.
Run `bundle lock --add-platform x86_64-linux` and commit the resulting lockfile;
CI uses frozen dependency installation and cannot add missing platforms itself.

## Run tests

Create a test database and migrate with the bundled Ruby command:

```shell
$ createdb river_test
$ bundle exec river migrate-up --database-url "postgres://localhost/river_test"
```

Run the core, SQL driver packages, and Rails integration, plus Redis and Pro
when their local packages are present:

```shell
$ RIVER_REQUIRE_DATABASES=1 make test
```

Real database tests run by default. `RIVER_REQUIRE_DATABASES=1` requires both
PostgreSQL and SQLite to be available instead of permitting local skips. CI
also requires them. Set `TEST_DATABASE_URL` to override the PostgreSQL test
database URL; it must already contain River's migrated tables in `public`.

Both driver packages run the same insertion and runtime contracts from
`spec/driver_shared_examples.rb` and `spec/driver_runtime_shared_examples.rb`
against PostgreSQL and SQLite. These cover job state transitions, scheduling,
rescue, metadata, filtering, deletion, transactions, queues, and leadership.
Adapter-specific conversion tests remain in each driver's suite.

`spec/client_driver_shared_examples.rb` additionally starts real worker threads
for each combination, testing transaction visibility and rollback, committed
bulk insertion, output, retries, and exhausted jobs. These tests need committed
data, so they use disposable PostgreSQL schemas and temporary file-backed SQLite
databases, initialized by `River::Migrator` with the bundled canonical SQL, not
the shared public job tables. PostgreSQL tests need permission to create and
drop schemas. Shared migration contracts also cover upgrades, downgrades,
legacy history, rollback, and populated data. See [migrations](migrations.md)
for synchronizing the SQL with upstream Go.

`bundle exec rspec spec` from the repository root runs only the core suite;
use `make test` for the SQL adapter matrix, Rails, and optional Redis and Pro suites.
The optional suites run only when `driver/riverqueue-redis` or `pro/riverqueue-pro`
exists. Missing packages are skipped; failures in present packages still fail
the test run.

Redis also has driver-local targets for running its suite independently and
verifying Go interoperability. When working on the local experimental driver,
install Redis 7+ (`redis-server` on PATH) and run:

```shell
$ make -C driver/riverqueue-redis install
$ make -C driver/riverqueue-redis test
$ make -C driver/riverqueue-redis verify RIVER_PATH=/path/to/river
```

The Redis suite starts a disposable server on a private Unix socket with
persistence disabled; it never flushes a shared Redis database. It runs the
shared runtime and client contracts plus key/index, conflict, and atomicity tests.
The driver-local `verify` target also compares the bundled Lua scripts
and builds a Go helper that verifies real Go/Ruby interoperability. This requires
a Go checkout containing the experimental `riverredisv9` driver and its Go
toolchain. Redis and Pro are held back from the public release and are not built,
linted, or tested by CI. Their local implementations and test suites remain available.

## Verify migrations

Check bundled PostgreSQL and SQLite migrations against the local Go checkout:

```shell
$ make verify
$ make verify RIVER_PATH=/path/to/river
```

`RIVER_PATH` defaults to `../river`. Verification checks the exact SQL files,
license, and manifest, including the upstream commit. It needs only Ruby and Git,
not Go, database access, or installed gems. CI checks out `riverqueue/river` at
the revision in `migration/manifest.json` and runs the same target. This verifies
the recorded source, not whether newer migrations have been published upstream.
See [updating the bundled SQL](migrations.md#updating-the-bundled-sql) to update
the files and recorded revision together.

## Run lint

```shell
$ bundle exec standardrb --fix
```

## Run type check (Steep)

```shell
$ bundle exec steep check
```

## Code coverage

The core and driver suites require 100% line and branch coverage of production
code; shared test files are excluded. Run the suite and open
`coverage/index.html` to find lines or branches that weren't covered:

```shell
$ bundle exec rspec spec
$ open coverage/index.html
```

## Publish gems

1. Choose a version, run scripts to update the versions in each gemspec file, build each gem, and `bundle install` which will update its `Gemfile.lock` with the new version:

    ```shell
    git checkout master && git pull --rebase
    export VERSION=v0.x.0

    ruby scripts/update_gemspec_version.rb riverqueue.gemspec
    ruby scripts/update_gemspec_version.rb driver/riverqueue-activerecord/riverqueue-activerecord.gemspec
    ruby scripts/update_gemspec_version.rb driver/riverqueue-redis/riverqueue-redis.gemspec
    ruby scripts/update_gemspec_version.rb driver/riverqueue-sequel/riverqueue-sequel.gemspec
    ruby scripts/update_gemspec_version.rb rails/riverqueue-rails/riverqueue-rails.gemspec
    ruby scripts/update_gemspec_version.rb pro/riverqueue-pro/riverqueue-pro.gemspec

    gem build riverqueue.gemspec
    pushd driver/riverqueue-activerecord && gem build riverqueue-activerecord.gemspec && popd
    pushd driver/riverqueue-redis && gem build riverqueue-redis.gemspec && popd
    pushd driver/riverqueue-sequel && gem build riverqueue-sequel.gemspec && popd
    pushd rails/riverqueue-rails && gem build riverqueue-rails.gemspec && popd
    pushd pro/riverqueue-pro && gem build riverqueue-pro.gemspec && popd

    bundle install
    pushd driver/riverqueue-activerecord && bundle install && popd
    pushd driver/riverqueue-redis && bundle install && popd
    pushd driver/riverqueue-sequel && bundle install && popd
    pushd rails/riverqueue-rails && bundle install && popd
    pushd pro/riverqueue-pro && bundle install && popd

    gco -b $USER-$VERSION
    ```

2. Update `CHANGELOG.md` to include the new version and open a pull request with those changes and the ones to the gemspecs and `Gemfile.lock`s above.

3. Build and push each gem, then tag the release and push that:

    ```shell
    git pull origin master
    export RIVERQUEUE_PRO_GEM_HOST=https://YOUR_PRIVATE_GEM_REGISTRY

    gem push riverqueue-${"${VERSION}"/v/}.gem
    pushd driver/riverqueue-activerecord && gem push riverqueue-activerecord-${"${VERSION}"/v/}.gem && popd
    pushd driver/riverqueue-redis && gem push riverqueue-redis-${"${VERSION}"/v/}.gem && popd
    pushd driver/riverqueue-sequel && gem push riverqueue-sequel-${"${VERSION}"/v/}.gem && popd
    pushd rails/riverqueue-rails && gem push riverqueue-rails-${"${VERSION}"/v/}.gem && popd
    pushd pro/riverqueue-pro && gem push riverqueue-pro-${"${VERSION}"/v/}.gem --host "$RIVERQUEUE_PRO_GEM_HOST" && popd

    git tag $VERSION
    git push --tags
    ```

4. Cut a new GitHub release by visiting [new release](https://github.com/riverqueue/riverqueue-ruby/releases/new), selecting the new tag, and copying in the version's `CHANGELOG.md` content as the release body.
