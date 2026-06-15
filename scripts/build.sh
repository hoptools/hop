#!/usr/bin/env bash
# Build every HopUI target (both toolkits). Pass extra args through, e.g. `scripts/build.sh -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift build "$@"
