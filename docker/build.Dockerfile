FROM debian:12

# Pin the Rust release; keep it equal to the toolchain in docker/verify.Dockerfile.
ARG RUST_TOOLCHAIN=1.100.0
# Pin the Go release used to cross-compile UAmask (package/uamask is built from upstream source).
ARG GO_VERSION=1.27.4
ARG GO_SHA256=7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential bison flex file gawk gettext git libncurses-dev \
        libssl-dev libelf-dev python3 python3-setuptools rsync unzip wget \
        curl zstd xz-utils openssl ca-certificates which xsltproc qemu-utils \
        qemu-system-x86 ovmf seabios \
    && rm -rf /var/lib/apt/lists/*

ENV CARGO_HOME=/opt/cargo RUSTUP_HOME=/opt/rustup
ENV PATH="/opt/cargo/bin:/opt/go/bin:${PATH}"

RUN work="$(mktemp -d)" \
    && cd "$work" \
    && curl --fail --show-error --silent --location \
        "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o go.tar.gz \
    && printf '%s  go.tar.gz\n' "$GO_SHA256" | sha256sum --check - \
    && tar -C /opt -xzf go.tar.gz \
    && chmod -R a+rX /opt/go \
    && cd / \
    && rm -rf "$work"

RUN work="$(mktemp -d)" \
    && cd "$work" \
    && rustup_url=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu \
    && curl --fail --show-error --silent --location "$rustup_url/rustup-init" -o rustup-init \
    && curl --fail --show-error --silent --location "$rustup_url/rustup-init.sha256" -o rustup-init.sha256 \
    && awk '{ print $1 "  rustup-init" }' rustup-init.sha256 | sha256sum --check - \
    && chmod +x rustup-init \
    && ./rustup-init -y --no-modify-path --profile minimal \
        --default-toolchain "$RUST_TOOLCHAIN" --target x86_64-unknown-linux-musl \
    && cd / \
    && rm -rf "$work" \
    && useradd --create-home --home-dir /opt/builder --shell /bin/bash builder \
    && mkdir -p /work \
    && chown -R builder:builder /work /opt/cargo /opt/rustup

USER builder
ENV CATWRT_IN_CONTAINER=1
WORKDIR /src
