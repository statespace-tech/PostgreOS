.PHONY: check integration

check:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace

integration:
	test -n "$$PGOS_TEST_DATABASE_URL"
	cargo test --workspace
