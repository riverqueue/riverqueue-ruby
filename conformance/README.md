# Ruby conformance

The adapter currently serves **only PostgreSQL `insert-only-v1`** through either
Sequel or Active Record. It uses production insertion, transactions, and unique
keys. The upstream Go harness observes the rows and works the inserted jobs.
This is not a claim that the full Ruby runtime is conformant.

## Run

Install the root bundle and the Go toolchain specified by the pinned River
checkout. Use an isolated checkout rather than changing an active Go branch:

```sh
git clone --branch bg/plan-interoperable-rust-river-port \
  https://github.com/riverqueue/river.git /path/to/river-conformance
createdb river_ruby_conformance

RIVER_CONFORMANCE_DATABASE_URL=postgres://localhost/river_ruby_conformance \
  make test/conformance/insert-only RIVER_PATH=/path/to/river-conformance

RIVER_CONFORMANCE_DATABASE_URL=postgres://localhost/river_ruby_conformance \
  RIVER_CONFORMANCE_DRIVER=activerecord \
  make test/conformance/insert-only RIVER_PATH=/path/to/river-conformance
```

**The database must be disposable: upstream scenarios reset its River tables.**
Do not run both drivers concurrently against the same database.

`reference.json` pins the harness revision. `run.rb` makes a temporary local
clone of `RIVER_PATH` at that revision, adds Ruby's package/version to its
manifest, verifies the fixture and scenario inventory, and runs the unmodified
upstream insert-only target with `RIVER_CONFORMANCE_REQUIRED=1`. Neither the
source checkout nor its branches are changed. No expected results or scenarios
are removed. Candidate registration stays local until it can be upstreamed.

Adapter protocol tests run with:

```sh
RIVER_PATH=/path/to/river-conformance bundle exec rspec conformance/spec
```

`scenario-coverage.json` accounts for every scenario in the declared profile.
`fixtures/unique_keys.json` is copied verbatim from the pinned River revision;
the ordinary Ruby suite checks all cases, including the typed-only fixtures.
Update the pin, fixture, and coverage inventory together when updating upstream.
The source is licensed under the same MPL-2.0 license as this project.

## Remaining work

| Profile / gate | Status |
| --- | --- |
| PostgreSQL insert-only, Sequel and Active Record | Adapter implemented; required CI gate |
| PostgreSQL storage and runtime | Not advertised; adapter and production parity work remain |
| SQLite storage and runtime | Existing Ruby driver tests pass; shared conformance not run |
| Go/Rust/JS multi-engine, performance, soak | Not run; require the storage/runtime profiles first |
| Pro | Out of scope; separate repository |

The first runtime audit found these gaps; this is not yet a complete accounting
of every feature-inventory item:

- Ruby polls for work and cancellation; it does not consume PostgreSQL LISTEN
  notifications or SQLite's notification log. Insertion and cancellation emit
  commit-bound notifications; other control paths still need implementation,
  and runtime notification behavior needs shared conformance coverage.
- Runtime configuration does not expose Go's rescue horizon, stuck-job callback,
  or all maintenance controls.
- Shared CRUD/cursor byte formats, exact JSON-number decoding, migration
  comparisons, periodic/leadership behavior, and concurrent completion/rescue
  semantics still need the upstream scenarios. Local tests are not a substitute.
- SQLite connection ownership, WAL/busy-timeout behavior, and interop contention
  must be checked before advertising the SQLite profiles.

Follow `feature-inventory.json` and `feature-matrix.md` in the pinned checkout
when expanding this list and adding the remaining profiles. Do not enable a
profile by stubbing adapter methods or implement queue behavior in the adapter.

## Intentional API differences

- Sequel/Active Record transactions are scoped blocks on the application's
  connection, not explicit Go transaction arguments. Adapter transaction handles
  keep those native blocks open on dedicated threads across protocol requests.
- Selected unique fields use `by_args: [:field, [:nested, :field]]`, not Go
  struct tags or a string-path query language. String keys containing dots stay
  literal. Missing selections and raw value bytes follow Go.
- Applications provide JSON with `args.to_json`. Equivalent decoded JSON is not
  enough for cross-language uniqueness: producers must agree on encoded values,
  including escaping, numeric lexemes, and nested ordering. River sorts only
  the top-level keys for all-argument uniqueness; it does not canonicalize
  application payloads or modify Ruby's global JSON settings.
- Ruby workers use exceptions and thread interruption rather than Go contexts
  and returned errors. Full persisted-outcome equivalence remains to be tested.
- Ruby list cursors store the explicitly selected field and its value, rather
  than inferring a time field from job state. Nullable timestamps retain Ruby's
  documented nulls-last ordering in both directions; Go reverses null ordering.
- Historical error timestamps retain Ruby's existing `Time.parse` formats,
  including PostgreSQL text timestamps that Go treats as zero. Unreadable
  timestamps use Go's zero time. Job metadata must decode to an object for
  Ruby's hash-based metadata API; other valid JSON shapes fail the attempt too.

Missing runtime features above are gaps to close, not intentional divergences.
