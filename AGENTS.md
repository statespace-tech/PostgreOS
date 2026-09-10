# PostgreOS contributor instructions

## Scope

Keep changes within the filesystem, SQL API, daemon, command, and packaging scope
described in `README.md` and tracked issues. Do not add hosted
infrastructure, agent orchestration, branching workflows, or a database-backed
root without an accepted issue or design discussion.

## Terminology

Use `PostgreOS` for the project. Call the mount component the `filesystem adapter`. Do not introduce another product name for it.

## Architecture

- Write production code in Rust.
- Use Diesel for PostgreSQL connections, pooling, and transactions.
- Put the supported database contract in the public `pgos` schema.
- Keep physical tables and invariants in `pgos_private`.
- Make the mount and SQL-aware tools call the public API.
- Map one logical filesystem command to one daemon request and one set-based
  PostgreSQL query or transaction. Use bounded streaming when one response
  cannot safely contain the result.
- Do not issue one database query per file for a bulk command.
- Preserve standard tool behavior. Fall back before mutation when an optimized path cannot preserve it.
- Do not fall back after a SQL mutation has started or completed.
- Prefer maintained crates and upstream implementations over custom replacements.

## Quality

- Add comments where they explain an invariant, compatibility rule, or non-obvious decision.
- Keep comments current. Do not repeat the code in prose.
- Format with `cargo fmt --all --check`.
- Lint with `cargo clippy --all-targets --all-features -- -D warnings` when the host supports all features.
- Run `cargo test`.
- Run PostgreSQL integration tests when `PGOS_TEST_DATABASE_URL` is set.
- Add differential tests for each SQL-aware tool behavior.
- Keep paths and errors explicit. Reject unsupported filename encodings rather than changing them silently.
- Do not claim POSIX or command compatibility without tests.

## Documentation

Use an alternating prose and visual rhythm in README sections:

- Follow one paragraph with one list, code block, table, or diagram.
- Do not place two paragraphs together.
- Do not place two visual elements together.
- Keep the README focused on operation and architecture, not repository layout.
