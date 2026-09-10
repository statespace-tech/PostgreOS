# syntax=docker/dockerfile:1.7

# Keep the build environment on the same Debian release as the runtime image.
FROM rust:1.88-bookworm AS builder

RUN apt-get update \
    && apt-get install --yes --no-install-recommends libpq-dev postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    cargo build --workspace --release

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        fuse3 \
        libpq5 \
        postgresql-client \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/pgos /usr/local/bin/pgos
COPY --from=builder /src/target/release/pgosd /usr/local/bin/pgosd
COPY --from=builder /src/target/release/pgos-mount /usr/local/bin/pgos-mount
COPY --chmod=0755 scripts/docker-mount-smoke.sh /usr/local/bin/docker-mount-smoke
COPY --chmod=0755 scripts/postgreos-entrypoint.sh /usr/local/bin/postgreos-entrypoint

RUN mkdir -p /opt/postgreos/bin /workspace \
    && pgos tools install /opt/postgreos/bin

ENV PATH="/opt/postgreos/bin:${PATH}"
ENV PGOS_MOUNT=/workspace

ENTRYPOINT ["postgreos-entrypoint"]
CMD ["/bin/bash"]
