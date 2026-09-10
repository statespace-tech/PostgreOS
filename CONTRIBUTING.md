# Contributing

Thank you for contributing to PostgreOS.

## Before you start

Read [README.md](README.md) and [AGENTS.md](AGENTS.md). Open an issue before a large
design or storage-format change.

## Development checks

Run the local checks:

```bash
make check
```

Set `PGOS_TEST_DATABASE_URL` to run the PostgreSQL integration tests:

```bash
export PGOS_TEST_DATABASE_URL=postgresql:///pgos_test
make integration
```

You can also run the disposable Docker test environment:

```bash
docker compose up --build --abort-on-container-exit --exit-code-from test test
```

## Pull requests

- Keep each change focused.
- Add tests for behavior changes and bug fixes.
- Preserve standard command behavior when you add an accelerated path.
- Explain public SQL, protocol, or storage-format changes.
- Update documentation for user-visible changes.

Contributions must be compatible with GPL-3.0. Files derived from another
project must retain the applicable copyright and license notices.
