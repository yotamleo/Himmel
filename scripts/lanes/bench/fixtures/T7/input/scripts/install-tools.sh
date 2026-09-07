#!/usr/bin/env bash
# Installs the pinned build toolchain. Versions must match tools/pins.env.
set -eu

install_shellcheck() {
    local version="0.10.0"
    echo "installing shellcheck ${version}"
}

install_graphify() {
    local version="0.12.3"
    echo "installing graphify ${version}"
    curl -fsSL "https://example.invalid/graphify/v0.12.3/graphify-linux-amd64.tar.gz" -o /tmp/graphify.tgz
}

install_ripgrep() {
    local version="14.1.1"
    echo "installing ripgrep ${version}"
}

install_jq() {
    local version="1.7.1"
    echo "installing jq ${version}"
}

install_shellcheck
install_graphify
install_ripgrep
install_jq
