#!/usr/bin/env bash
# Install apt packages while caching the downloaded .deb files under ~/apt-cache, so CI doesn't re-download
# them on every run. The companion `actions/cache` step in .github/workflows/ci.yml restores/saves
# ~/apt-cache/archives/*.deb around the job — this script just makes apt read/write that directory.
#
# Why a custom archive dir instead of the default /var/cache/apt/archives:
#   - The default is root-owned, and actions/cache (which runs as the unprivileged runner user) can't
#     restore a cache into it. ~/apt-cache is runner-owned, so the cache round-trips cleanly.
#   - APT::Keep-Downloaded-Packages=true keeps the .deb files after install so the cache has something to
#     save (apt would otherwise be free to clean them).
#   - APT::Sandbox::User=root disables apt's download-sandbox: the sandbox `_apt` user can't write into the
#     runner-owned dir, which would otherwise downgrade to an "unsandboxed as root" warning per package.
#
# `apt-get update` still refreshes the package indexes first, so a cached .deb is reused only when its
# version still matches the index — a cache hit never produces a stale install.
#
#   scripts/ci/apt-install.sh <package>...
set -euo pipefail

ARCHIVES="$HOME/apt-cache/archives"
mkdir -p "$ARCHIVES/partial"

sudo apt-get update
sudo apt-get \
  -o Dir::Cache::Archives="$ARCHIVES" \
  -o APT::Keep-Downloaded-Packages=true \
  -o APT::Sandbox::User=root \
  install -y "$@"
