#!/usr/bin/env bash
# Build the HopUI libraries + toolkits (root package), the hoppack packaging tool (Tools/HopPackaging), AND
# the demo apps (the Showcase sub-package, which also pulls in the HopUIComboBox component package). Pass
# extra args through, e.g. `scripts/build.sh -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building root package (HopUI libraries, toolkits)…"
swift build "$@"

echo "Building hoppack packaging tool…"
swift build --package-path Tools/HopPackaging "$@"

echo "Building Showcase demo apps…"
swift build --package-path Demos/Apps/Showcase "$@"
