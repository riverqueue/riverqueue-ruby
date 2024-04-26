.PHONY: lint
lint: standardrb

.PHONY: rspec
rspec: spec

.PHONY: spec
spec:
	bundle exec rspec
	cd drivers/riverqueue-activerecord && bundle exec rspec
	cd drivers/riverqueue-sequel && bundle exec rspec

.PHONY: standardrb
standardrb:
	bundle exec standardrb --fix
	cd drivers/riverqueue-activerecord && bundle exec standardrb --fix
	cd drivers/riverqueue-sequel && bundle exec standardrb --fix

.PHONY: steep
steep:
	bundle exec steep check

.PHONY: type-check
type-check: steep
