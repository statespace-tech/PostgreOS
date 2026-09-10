#!/bin/sh
set -eu

# FUSE is a kernel interface. A container runtime must expose it even when the
# PostgreOS binaries and PostgreSQL connection work correctly.
if [ ! -c /dev/fuse ]; then
    echo "docker-mount-smoke: /dev/fuse is not available" >&2
    exit 77
fi

pgos init

# Keep the smoke test repeatable when the database container is reused.
psql "$PGOS_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
SELECT pgos.create_volume(gen_random_uuid(), 'docker-smoke')
WHERE NOT EXISTS (
    SELECT 1 FROM pgos.volumes() WHERE name = 'docker-smoke'
);
SQL

pgos rm --recursive --force /docs

mkdir -p /data
rm -f "${PGOS_SOCKET:-/tmp/pgosd.sock}"
pgosd &
daemon_pid=$!

attempt=0
until [ -S "${PGOS_SOCKET:-/tmp/pgosd.sock}" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
        echo "docker-mount-smoke: daemon did not become ready" >&2
        exit 1
    fi
    sleep 0.1
done
export PGOS_SOCKET="${PGOS_SOCKET:-/tmp/pgosd.sock}"

pgos-mount --volume "$PGOS_VOLUME" /data &
mount_pid=$!

cleanup() {
    umount /data 2>/dev/null || true
    kill "$mount_pid" 2>/dev/null || true
    wait "$mount_pid" 2>/dev/null || true
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

attempt=0
until mountpoint --quiet /data; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
        echo "docker-mount-smoke: mount did not become ready" >&2
        exit 1
    fi
    sleep 0.1
done

# Verify both directions through independent interfaces.
mkdir /data/docs
printf 'written through fuse\n' > /data/docs/from-fuse.txt
test "$(cat /data/docs/from-fuse.txt)" = "written through fuse"
test "$(psql "$PGOS_DATABASE_URL" --tuples-only --no-align --command \
    "SELECT convert_from(pgos.read_file(id, '/docs/from-fuse.txt'), 'UTF8') FROM pgos.volumes() WHERE name = '$PGOS_VOLUME'")" = "written through fuse"

# GNU touch uses FUSE setattr after it creates or opens a file. Verify both
# creation and a caller-supplied timestamp.
touch -d '@1700000000' /data/docs/touched.txt
test -f /data/docs/touched.txt
test "$(stat -c %Y /data/docs/touched.txt)" = "1700000000"

pgos write /docs/from-sql.txt 'written through sql'
test "$(cat /data/docs/from-sql.txt)" = "written through sql"
grep --fixed-strings --quiet 'through sql' /data/docs/from-sql.txt

echo "docker-mount-smoke: passed"
