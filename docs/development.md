# riverqueue-ruby development

## Install dependencies

```shell
$ bundle install
$ pushd driver/riverqueue-activerecord && bundle install && popd
$ pushd driver/riverqueue-sequel && bundle install && popd
```
## Run tests

Create a test database and migrate with River's CLI:

```shell
$ go install github.com/riverqueue/river/cmd/river
$ createdb river_test
$ river migrate-up --database-url "postgres://localhost/river_test"
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

## Publish gems

1. Choose a version, run scripts to update the versions in each gemspec file, build each gem, and `bundle install` which will update its `Gemfile.lock` with the new version:

    ```shell
    git checkout master && git pull --rebase
    export VERSION=v0.x.0

    ruby scripts/update_gemspec_version.rb riverqueue.gemspec
    ruby scripts/update_gemspec_version.rb driver/riverqueue-activerecord/riverqueue-activerecord.gemspec
    ruby scripts/update_gemspec_version.rb driver/riverqueue-sequel/riverqueue-sequel.gemspec

    gem build riverqueue.gemspec
    pushd driver/riverqueue-activerecord && gem build riverqueue-activerecord.gemspec && popd
    pushd driver/riverqueue-sequel && gem build riverqueue-sequel.gemspec && popd

    bundle install
    pushd driver/riverqueue-activerecord && bundle install && popd
    pushd driver/riverqueue-sequel && bundle install && popd

    gco -b $USER-$VERSION
    ```

2. Update `CHANGELOG.md` to include the new version and open a pull request with those changes and the ones to the gemspecs and `Gemfile.lock`s above.

3. Build and push each gem, then tag the release and push that:

    ```shell
    git pull origin master

    gem push riverqueue-${"${VERSION}"/v/}.gem
    pushd driver/riverqueue-activerecord && gem push riverqueue-activerecord-${"${VERSION}"/v/}.gem && popd
    pushd driver/riverqueue-sequel && gem push riverqueue-sequel-${"${VERSION}"/v/}.gem && popd

    git tag $VERSION
    git push --tags
    ```

4. Cut a new GitHub release by visiting [new release](https://github.com/riverqueue/riverqueue-ruby/releases/new), selecting the new tag, and copying in the version's `CHANGELOG.md` content as the release body.
