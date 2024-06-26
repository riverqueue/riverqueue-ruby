# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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