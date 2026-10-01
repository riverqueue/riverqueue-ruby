.DEFAULT_GOAL := help

RIVER_PATH ?= ../river
RIVERQUEUE_PRO_PATH ?= ../riverqueue-ruby-pro
TEST_JOBS ?= 4

.PHONY: test/conformance/insert-only
test/conformance/insert-only: ## Run the pinned Go insert-only contract against Ruby
	RIVER_PATH="$(RIVER_PATH)" bundle exec ruby conformance/run.rb

.PHONY: test/yugabyte
test/yugabyte: ## Run both SQL adapters against a real Yugabyte database
	@test -n "$(YUGABYTE_DATABASE_URL)" || { echo "Set YUGABYTE_DATABASE_URL to a disposable test database"; exit 1; }
	cd driver/riverqueue-activerecord && TEST_DATABASE_URL="$(YUGABYTE_DATABASE_URL)" RIVER_YUGABYTE_TEST=1 RIVER_REQUIRE_DATABASES=1 RIVERQUEUE_ROOT_TEST_SUITE=1 bundle exec rspec spec/yugabyte_spec.rb
	cd driver/riverqueue-sequel && TEST_DATABASE_URL="$(YUGABYTE_DATABASE_URL)" RIVER_YUGABYTE_TEST=1 RIVER_REQUIRE_DATABASES=1 RIVERQUEUE_ROOT_TEST_SUITE=1 bundle exec rspec spec/yugabyte_spec.rb

# Looks at comments using ## on targets and uses them to produce a help output.
.PHONY: help
help: ALIGN=14
help: ## Print this message
	@awk -F ': .*## ' -- "/^[^':]+: .*## /"' { printf "'$$(tput bold)'%-$(ALIGN)s'$$(tput sgr0)' %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: install
install: ## Run `bundle install` on gem and all subgems
	bundle install
	cd driver/riverqueue-activerecord && bundle install
	cd driver/riverqueue-sequel && bundle install
	cd rails/riverqueue-rails && bundle install
	@if [ -f "$(RIVERQUEUE_PRO_PATH)/riverqueue-pro.gemspec" ]; then $(MAKE) -C "$(RIVERQUEUE_PRO_PATH)" install; fi

.PHONY: lint
lint: standardrb frozen-string-literals ## Run linters on gem and all subgems

.PHONY: rspec
rspec: spec

.PHONY: spec
spec:
	$(MAKE) -j$(TEST_JOBS) spec/all

.PHONY: spec/all spec/core spec/activerecord spec/sequel spec/rails spec/redis spec/pro
spec/all: spec/core spec/activerecord spec/sequel spec/rails spec/redis spec/pro

spec/core:
	bundle exec rspec

spec/activerecord:
	cd driver/riverqueue-activerecord && bundle exec rspec

spec/sequel:
	cd driver/riverqueue-sequel && bundle exec rspec

spec/rails:
	cd rails/riverqueue-rails && bundle exec rspec

spec/redis:
	@if [ -d driver/riverqueue-redis ]; then cd driver/riverqueue-redis && bundle exec rspec; fi

spec/pro:
	@if [ -f "$(RIVERQUEUE_PRO_PATH)/riverqueue-pro.gemspec" ]; then $(MAKE) -C "$(RIVERQUEUE_PRO_PATH)" test; fi

.PHONY: standardrb
standardrb:
	bundle exec standardrb --fix
	cd driver/riverqueue-activerecord && bundle exec standardrb --fix
	cd driver/riverqueue-sequel && bundle exec standardrb --fix
	cd rails/riverqueue-rails && bundle exec standardrb --fix
	@if [ -f "$(RIVERQUEUE_PRO_PATH)/riverqueue-pro.gemspec" ]; then $(MAKE) -C "$(RIVERQUEUE_PRO_PATH)" standardrb; fi

.PHONY: frozen-string-literals
frozen-string-literals:
	bundle exec rubocop --config .rubocop-frozen-string-literal.yaml --only Style/FrozenStringLiteralComment

.PHONY: steep
steep:
	bundle exec steep check

.PHONY: test
test: spec ## Run test suite (rspec) on gem and all subgems

.PHONY: type-check
type-check: steep ## Run type check with Steep

.PHONY: update
update: ## Run `bundle update` on gem and all subgems
	bundle update
	cd driver/riverqueue-activerecord && bundle update
	cd driver/riverqueue-sequel && bundle update
	cd rails/riverqueue-rails && bundle update
	@if [ -f "$(RIVERQUEUE_PRO_PATH)/riverqueue-pro.gemspec" ]; then $(MAKE) -C "$(RIVERQUEUE_PRO_PATH)" update; fi

.PHONY: verify
verify: ## Verify bundled migrations against RIVER_PATH (default ../river)
	ruby scripts/sync_migrations.rb --check "$(RIVER_PATH)"
