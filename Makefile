.DEFAULT_GOAL := help

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

.PHONY: lint
lint: standardrb ## Run linter (standardrb) on gem and all subgems

.PHONY: rspec
rspec: spec

.PHONY: spec
spec:
	bundle exec rspec
	cd driver/riverqueue-activerecord && bundle exec rspec
	cd driver/riverqueue-sequel && bundle exec rspec

.PHONY: standardrb
standardrb:
	bundle exec standardrb --fix
	cd driver/riverqueue-activerecord && bundle exec standardrb --fix
	cd driver/riverqueue-sequel && bundle exec standardrb --fix

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
