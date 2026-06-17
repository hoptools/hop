#!/usr/bin/env bash
# Install a hoppack-produced .flatpak bundle and verify the app launches — the Linux half of the CI install
# smoke test. Installs the bundle for the user, then runs it under Xvfb: if it stays alive until the timeout
# (or exits cleanly) it launched OK; an early nonzero exit (a crash / missing library) fails the CI job.
#
#   scripts/ci/linux-install-launch.sh <flatpak-bundle> <app-id>
set -euo pipefail

BUNDLE="${1:?usage: linux-install-launch.sh <flatpak-bundle> <app-id>}"
APPID="${2:?app-id required}"
[ -f "$BUNDLE" ] || { echo "::error::flatpak bundle not found: $BUNDLE"; exit 1; }

echo "Installing $BUNDLE"
flatpak install --user --noninteractive --bundle "$BUNDLE"

echo "Launching $APPID under Xvfb (up to 12s)"
set +e
timeout -s KILL 12 xvfb-run -a flatpak run --user "$APPID"
code=$?
set -e

# timeout -s KILL → 124 (timed out) / 137 (128+SIGKILL): the app was still running, i.e. it launched.
# 0: the app exited cleanly. Any other code is a real launch failure (crash / missing dependency).
case "$code" in
  0|124|137) echo "✓ Linux install + launch succeeded for $APPID (exit $code)" ;;
  *) echo "::error::$APPID failed to launch (exit $code)"; exit 1 ;;
esac
