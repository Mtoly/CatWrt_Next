FROM rust:1-bookworm

ARG SHELLCHECK_VERSION=0.9.0-1
ARG SHFMT_VERSION=3.6.0-1+b2
ARG NODE_VERSION=22.14.0
ARG ACTIONLINT_VERSION=1.7.7
ARG GITLEAKS_VERSION=8.24.3

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils \
        shellcheck="${SHELLCHECK_VERSION}" shfmt="${SHFMT_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && rustup component add rustfmt clippy \
    && rustup target add x86_64-unknown-linux-musl

# Exact binary checksums are resolved from the pinned releases at build time.
# Checksum manifests are downloaded over HTTPS from the same upstream release.
RUN work="$(mktemp -d)" \
    && cd "$work" \
    && architecture="$(dpkg --print-architecture)" \
    && case "$architecture" in amd64|arm64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac \
    && actionlint_archive="actionlint_${ACTIONLINT_VERSION}_linux_${architecture}.tar.gz" \
    && gitleaks_architecture="$architecture" \
    && if [[ "$architecture" == amd64 ]]; then gitleaks_architecture=x64; fi \
    && gitleaks_archive="gitleaks_${GITLEAKS_VERSION}_linux_${gitleaks_architecture}.tar.gz" \
    && node_archive="node-v${NODE_VERSION}-linux-${gitleaks_architecture}.tar.xz" \
    && node_url="https://nodejs.org/dist/v${NODE_VERSION}" \
    && actionlint_url="https://github.com/rhysd/actionlint" \
    && gitleaks_url="https://github.com/gitleaks/gitleaks" \
    && fetch() { curl --fail-with-body --show-error --location --retry 3 \
        --write-out 'download: status=%{http_code} type=%{content_type} url=%{url_effective}\n' \
        --output "$2" "$1"; } \
    && verify_checksum() { \
        awk -v name="$2" '$2 == name || $2 == "*" name { print $1 "  " name; found = 1 } END { if (!found) { print "Missing published checksum for " name > "/dev/stderr"; exit 1 } }' "$1" > selected.sha256 \
        && sha256sum --check selected.sha256; } \
    && fetch "${node_url}/${node_archive}" "$node_archive" \
    && fetch "${node_url}/SHASUMS256.txt" node-checksums \
    && verify_checksum node-checksums "$node_archive" \
    && tar -xJf "$node_archive" -C /usr/local --strip-components=1 \
    && npm install --global prettier@3 \
    && fetch "${actionlint_url}/releases/download/v${ACTIONLINT_VERSION}/${actionlint_archive}" "$actionlint_archive" \
    && fetch "${actionlint_url}/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_checksums.txt" actionlint-checksums \
    && verify_checksum actionlint-checksums "$actionlint_archive" \
    && tar -xzf "$actionlint_archive" -C /usr/local/bin actionlint \
    && fetch "${gitleaks_url}/releases/download/v${GITLEAKS_VERSION}/${gitleaks_archive}" "$gitleaks_archive" \
    && fetch "${gitleaks_url}/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_checksums.txt" gitleaks-checksums \
    && verify_checksum gitleaks-checksums "$gitleaks_archive" \
    && tar -xzf "$gitleaks_archive" -C /usr/local/bin gitleaks \
    && cd / \
    && rm -rf "$work"

# Keep build output outside the source mount, including for non-root callers.
ENV CARGO_TARGET_DIR=/tmp/target
WORKDIR /src
