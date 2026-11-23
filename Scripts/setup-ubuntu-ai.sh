#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clang ninja-build pkg-config zip unzip \
  binutils gnupg2 libc6-dev libedit2 libpython3-dev \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev \
  libssl-dev zlib1g-dev libz3-dev \
  avahi-daemon avahi-utils

sudo systemctl enable --now avahi-daemon

if ! command -v swiftly >/dev/null 2>&1 && [ ! -x "$HOME/.local/share/swiftly/bin/swiftly" ]; then
  curl -fL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" -o /tmp/swiftly.tar.gz
  mkdir -p /tmp/swiftly-extract
  tar zxf /tmp/swiftly.tar.gz -C /tmp/swiftly-extract
  /tmp/swiftly-extract/swiftly init --quiet-shell-followup -y
  rm -rf /tmp/swiftly.tar.gz /tmp/swiftly-extract
fi

source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
swiftly link >/dev/null 2>&1 || true
swift --version
