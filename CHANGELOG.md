# Changelog

All notable PostgreOS changes will be documented in this file.

The project uses [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Added the initial `postgreos` Cargo package.
- Added the `pgos`, `pgosd`, and `pgos-mount` binaries.
- Added a PostgreSQL-backed FUSE filesystem adapter for Linux.
- Added the public `pgos` SQL API and private `pgos_private` storage schema.
- Added SQL-aware search and recursive file operations.
- Added atomic directory import through PostgreSQL `COPY`.
- Added Debian container integration and mount tests.
- Added tag-based crates.io, GitHub Release, and OCI image automation.
