#!/bin/sh
set -eu

: "${PGOS_DATABASE_URL:?set PGOS_DATABASE_URL to a PostgreSQL connection string}"

export PGOS_VOLUME="${PGOS_VOLUME:-development}"
export PGOS_SOCKET="${PGOS_SOCKET:-/run/postgreos/pgosd.sock}"
export PGOS_MOUNT="${PGOS_MOUNT:-/workspace}"

mkdir -p "$(dirname "$PGOS_SOCKET")" "$PGOS_MOUNT"
pgos init

volume_exists=$(
    psql "$PGOS_DATABASE_URL" --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --set "volume_name=$PGOS_VOLUME" <<'SQL'
SELECT EXISTS (
    SELECT 1 FROM pgos.volumes() WHERE name = :'volume_name'
);
SQL
)
if [ "$volume_exists" != "t" ]; then
    pgos volume create "$PGOS_VOLUME" >/dev/null
fi

pgosd --database-url "$PGOS_DATABASE_URL" --socket "$PGOS_SOCKET" &
daemon_pid=$!

attempt=0
until [ -S "$PGOS_SOCKET" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        echo "postgreos: daemon did not become ready" >&2
        exit 1
    fi
    sleep 0.1
done

if [ "${PGOS_NO_MOUNT:-false}" != "true" ]; then
    if [ ! -c /dev/fuse ]; then
        echo "postgreos: /dev/fuse is not available" >&2
        echo "postgreos: expose FUSE or set PGOS_NO_MOUNT=true" >&2
        exit 1
    fi

    mount_options=""
    if [ "${PGOS_READ_ONLY:-false}" = "true" ]; then
        mount_options="--read-only"
    fi
    # Word splitting is intentional. mount_options is empty or one fixed flag.
    # shellcheck disable=SC2086
    pgos-mount --socket "$PGOS_SOCKET" --volume "$PGOS_VOLUME" \
        $mount_options "$PGOS_MOUNT" &

    attempt=0
    until mountpoint --quiet "$PGOS_MOUNT"; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 100 ]; then
            echo "postgreos: filesystem did not become ready" >&2
            exit 1
        fi
        sleep 0.1
    done
fi

if [ "$#" -eq 0 ]; then
    set -- /bin/bash
fi

exec "$@"
