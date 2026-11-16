FROM rust:1.99-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY schema.sql ./
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked \
    && cp target/release/noter-server /noter-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 noter && useradd --uid 10001 --gid noter --no-create-home noter \
    && mkdir -p /app/data/blobs && chown -R noter:noter /app
WORKDIR /app
COPY --from=builder /noter-server /usr/local/bin/noter-server
COPY config ./config
USER noter
ENV BLOB_DIR=/app/data/blobs
EXPOSE 5150
ENTRYPOINT ["noter-server"]
CMD ["start", "--environment", "production"]
