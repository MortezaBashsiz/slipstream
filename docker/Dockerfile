# syntax=docker/dockerfile:1.6

FROM rust:1-bookworm AS builder

ARG REPO_HTTPS="https://github.com/Mygod/slipstream-rust.git"
ARG CARGO_PROFILE="release"

WORKDIR /src

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    git ca-certificates curl openssl \
    build-essential cmake make pkg-config libssl-dev \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --recursive "${REPO_HTTPS}" /src

RUN if [ "${CARGO_PROFILE}" = "release" ]; then \
      cargo build -p slipstream-client -p slipstream-server --release ; \
    else \
      cargo build -p slipstream-client -p slipstream-server ; \
    fi

FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && apt-get install -y --no-install-recommends \
    ca-certificates openssl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/slipstream

COPY --from=builder /src/target/release/slipstream-client /usr/local/bin/slipstream-client
COPY --from=builder /src/target/release/slipstream-server /usr/local/bin/slipstream-server

