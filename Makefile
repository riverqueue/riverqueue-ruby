.DEFAULT_GOAL := help

RIVER_PATH ?= ../river

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
	@if [ -d pro/riverqueue-pro ]; then cd pro/riverqueue-pro && bundle install; fi

.PHONY: lint
lint: standardrb frozen-string-literals ## Run linters on gem and all subgems

.PHONY: rspec
rspec: spec

.PHONY: spec
spec:
	bundle exec rspec
	cd driver/riverqueue-activerecord && bundle exec rspec
	cd driver/riverqueue-sequel && bundle exec rspec
	cd rails/riverqueue-rails && bundle exec rspec
	@if [ -d driver/riverqueue-redis ]; then cd driver/riverqueue-redis && bundle exec rspec; fi
	@if [ -d pro/riverqueue-pro ]; then cd pro/riverqueue-pro && bundle exec rspec; fi

.PHONY: standardrb
standardrb:
	bundle exec standardrb --fix
	cd driver/riverqueue-activerecord && bundle exec standardrb --fix
	cd driver/riverqueue-sequel && bundle exec standardrb --fix
	cd rails/riverqueue-rails && bundle exec standardrb --fix
	@if [ -d pro/riverqueue-pro ]; then cd pro/riverqueue-pro && bundle exec standardrb --fix; fi

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
	@if [ -d pro/riverqueue-pro ]; then cd pro/riverqueue-pro && bundle update; fi

.PHONY: verify
verify: ## Verify bundled migrations against RIVER_PATH (default ../river)
	ruby scripts/sync_migrations.rb --check "$(RIVER_PATH)"
