# PostgreOS

PostgreOS is a Debian environment with a PostgreSQL-backed filesystem. It mounts a
local or remote PostgreSQL volume at `/workspace`. PostgreOS is an early release. Use
disposable data while you evaluate it.

## Run PostgreOS

The OCI image is the primary distribution. It supports `linux/amd64` and
`linux/arm64`.

```bash
docker pull ghcr.io/statespace-tech/postgreos:0.1.0

docker run --rm -it \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  --network host \
  -e PGOS_DATABASE_URL=postgresql://postgres@localhost/postgres \
  -e PGOS_VOLUME=development \
  ghcr.io/statespace-tech/postgreos:0.1.0
```

The host must use Linux and expose FUSE. The PostgreSQL role must be able to create
schemas, tables, functions, and indexes. From a repository clone, run the included
PostgreOS stack:

```bash
docker compose up -d
docker compose exec postgreos bash
```

## How it works

PostgreSQL stores the files, directories, contents, and metadata. PostgreOS provides:

- A FUSE mount for standard Linux file access.
- `pgosd`, which keeps PostgreSQL connections open.
- A public SQL API in the `pgos` schema.
- SQL-aware `grep`, `find`, `locate`, `du`, recursive `cp`, and recursive `rm`.

The image initializes the schema and volume. It then starts `pgosd`, mounts
`/workspace`, and opens Bash. Standard programs use the mount. Supported search and
recursive commands use set-based SQL. Other command forms use Debian tools.

```bash
cd /workspace
mkdir source
printf 'hello from PostgreOS\n' > source/example.txt
grep -r hello .
find . -type f
```

The OCI image is Debian user space, not a bootable VM disk. Use these runtime options
when you do not need the default writable mount:

- Set `PGOS_READ_ONLY=true` for a read-only mount.
- Set `PGOS_NO_MOUNT=true` to use SQL-aware commands without FUSE.

## Other installation methods

GitHub releases provide Linux binaries. Rust users can install the same programs
from crates.io:

```bash
cargo install postgreos
```

## Build

PostgreOS requires Rust 1.88 or newer, PostgreSQL 14 or newer, and PostgreSQL client
libraries. Filesystem mounts also require Linux and FUSE 3.

```bash
cargo build --workspace
cargo test --workspace
```

## Limits

The first release has these known limits:

- Paths must contain valid UTF-8.
- The mount implements a limited POSIX operation set.
- Links and extended attributes are not implemented.
- Multi-user authorization is not ready.
- The schema can change before version 1.0.

## License

PostgreOS is licensed under [GPL-3.0](LICENSE).
