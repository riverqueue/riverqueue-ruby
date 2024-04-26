# riverqueue-ruby development

## Install dependencies

```shell
$ bundle install
```
## Run tests

Create a test database and migrate with River's CLI:

```shell
$ go install github.com/riverqueue/river/cmd/river
$ createdb riverqueue_ruby_test
$ river migrate-up --database-url "postgres://localhost/riverqueue_ruby_test"
```

Run all specs:

```shell
$ bundle exec rspec spec
```

## Run lint

```shell
$ bundle exec standardrb --fix
```

## Run type check (Steep)

```shell
$ bundle exec steep check
```

## Code coverage

Running the entire test suite will produce a coverage report, and will fail if line and branch coverage is below 100%. Run the suite and open `coverage/index.html` to find lines or branches that weren't covered:

```shell
$ bundle exec rspec spec
$ open coverage/index.html
```

## Publish a new gem

```shell
git checkout master && git pull --rebase
VERSION=v0.0.x
gem build riverqueue.gemspec
gem push riverqueue-$VERSION.gem
pushd drivers/riverqueue-activerecord && gem build riverqueue-activerecord.gemspec && popd
pushd drivers/riverqueue-activerecord && gem push riverqueue-activerecord-$VERSION.gem && popd
pushd drivers/riverqueue-sequel && gem build riverqueue-sequel.gemspec && popd
pushd drivers/riverqueue-sequel && gem push riverqueue-sequel-$VERSION.gem && popd
git tag $VERSION
git push --tags
```