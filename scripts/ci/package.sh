#!/usr/bin/env bash
# Build the `hoppack` packaging tool (root package) and run it against the Showcase demo package to produce
# an installer. hoppack uses its current directory as the package dir (and builds the demo executable there),
# so we build the tool from the root and then invoke it with the Showcase package as the working directory.
#
#   scripts/ci/package.sh <target> <output-path>
set -euo pipefail
cd "$(dirname "$0")/../.."

TARGET="${1:?usage: package.sh <target> <output>}"
OUTPUT="${2:?usage: package.sh <target> <output>}"

swift build --product hoppack
HOPPACK="$(swift build --product hoppack --show-bin-path)/hoppack"

mkdir -p "$(dirname "$OUTPUT")"
OUTABS="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

cd Demos/Apps/Showcase
exec "$HOPPACK" package --target "$TARGET" --output "$OUTABS"
