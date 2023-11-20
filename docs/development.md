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
$ standardrb --fix
```

## Publish a new gem

```shell
git checkout master && git pull --rebase
VERSION=v0.0.x
gem build riverqueue.gemspec
gem push riverqueue-$VERSION.gem
git tag $VERSION
git push --tags
```