# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

⚠️ Version 0.8.0 contains breaking changes to transition to River's new unique jobs implementation and to enable broader, more flexible application of unique jobs. Detailed notes on the implementation are contained in [the original River PR](https://github.com/riverqueue/river/pull/590), and the notes below include short summaries of the ways this impacts this client specifically.

Users should upgrade backends to River v0.12.0 before upgrading this library in order to ensure a seamless transition of all in-flight jobs. Afterward, the latest River version may be used.

### Breaking

- **Breaking change:** The return type of `Client#insert_many` has been changed. Rather than returning just the number of rows inserted, it returns an array of all the `InsertResult` values for each inserted row. Unique conflicts which are skipped as duplicates are indicated in the same fashion as single inserts (the `unique_skipped_as_duplicated` attribute), and in such cases the conflicting row will be returned instead.
- **Breaking change:** Unique jobs no longer allow total customization of their states when using the `by_state` option. The pending, scheduled, available, and running states are required whenever customizing this list.

### Added

- The `UniqueOpts` class gains an `exclude_kind` option for cases where uniqueness needs to be guaranteed across multiple job types.
- Unique jobs utilizing `by_args` can now also opt to have a subset of the job's arguments considered for uniqueness. For example, you could choose to consider only the `customer_id` field while ignoring the other fields:

  ```ruby
  UniqueOpts.new(by_args: ["customer_id"])
  ```

  Any fields considered in uniqueness are also sorted alphabetically in order to guarantee a consistent result across implementations, even if the encoded JSON isn't sorted consistently.

### Changed

- Unique jobs have been improved to allow bulk insertion of unique jobs via `Client#insert_many`.

  This updated implementation is significantly faster due to the removal of advisory locks in favor of an index-backed uniqueness system, while allowing some flexibility in which job states are considered. However, not all states may be removed from consideration when using the `by_state` option; pending, scheduled, available, and running states are required whenever customizing this list.

## [0.7.0] - 2024-08-30

### Changed

- Now compatible with "fast path" unique job insertion that uses a unique index instead of advisory lock and fetch [as introduced in River #451](https://github.com/riverqueue/river/pull/451). [PR #28](https://github.com/riverqueue/riverqueue-ruby/pull/28).

## [0.6.1] - 2024-08-21

### Fixed

- Fix source files not being correctly included in built Ruby gems. [PR #26](https://github.com/riverqueue/riverqueue-ruby/pull/26).

## [0.6.0] - 2024-07-06

### Changed

- Advisory lock prefixes are now checked to make sure they fit inside of four bytes. [PR #24](https://github.com/riverqueue/riverqueue-ruby/pull/24).

## [0.5.0] - 2024-07-05

### Changed

- Tag format is now checked on insert. Tags should be no more than 255 characters and match the regex `/\A[\w][\w\-]+[\w]\z/`. [PR #22](https://github.com/riverqueue/riverqueue-ruby/pull/22).
- Returned jobs now have a `metadata` property. [PR #21](https://github.com/riverqueue/riverqueue-ruby/pull/22).

## [0.4.0] - 2024-04-28

### Changed

- Implement the FNV (Fowler–Noll–Vo) hashing algorithm in the project and drop dependency on the `fnv-hash` gem. [PR #14](https://github.com/riverqueue/riverqueue-ruby/pull/14).

## [0.3.0] - 2024-04-27

### Added

- Implement unique job insertion. [PR #10](https://github.com/riverqueue/riverqueue-ruby/pull/10).

## [0.2.0] - 2024-04-27

### Added

- Implement `#insert_many` for batch job insertion. [PR #5](https://github.com/riverqueue/riverqueue-ruby/pull/5).

## [0.1.0] - 2024-04-25

### Added

- Initial implementation that supports inserting jobs using either ActiveRecord or Sequel. [PR #1](https://github.com/riverqueue/riverqueue-ruby/pull/1).
