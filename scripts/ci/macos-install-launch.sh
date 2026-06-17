#!/usr/bin/env bash
# Install a hoppack-produced .dmg and verify the app launches — the macOS half of the CI install smoke test.
# Mounts the dmg, copies the .app into the install directory (real install), launches it via LaunchServices,
# confirms the process comes up, then quits it. Exits nonzero (failing the CI job) if any step fails.
#
#   scripts/ci/macos-install-launch.sh <path-to-dmg> [install-dir]   (install-dir defaults to /Applications)
set -euo pipefail

DMG="${1:?usage: macos-install-launch.sh <dmg> [install-dir]}"
INSTALL_DIR="${2:-/Applications}"
[ -f "$DMG" ] || { echo "::error::dmg not found: $DMG"; exit 1; }

MNT="$(mktemp -d /tmp/hoppack-mnt.XXXXXX)"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Mounting $DMG"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null

APP_SRC="$(/usr/bin/find "$MNT" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP_SRC" ] || { echo "::error::no .app found inside $DMG"; exit 1; }
NAME="$(basename "$APP_SRC")"

mkdir -p "$INSTALL_DIR"
APP="$INSTALL_DIR/$NAME"
echo "Installing $NAME → $INSTALL_DIR"
rm -rf "$APP"
cp -R "$APP_SRC" "$INSTALL_DIR/"
hdiutil detach "$MNT" >/dev/null; trap - EXIT

EXE_PATH="$(/usr/bin/find "$APP/Contents/MacOS" -type f -perm +111 | head -1)"
[ -n "$EXE_PATH" ] || { echo "::error::no executable in $APP/Contents/MacOS"; exit 1; }
EXE_NAME="$(basename "$EXE_PATH")"   # plain name (no regex metacharacters) for pgrep matching
echo "Installed: $APP (executable: $EXE_NAME)"

echo "Launching…"
open "$APP"

launched=0
for _ in $(seq 1 30); do
  if pgrep -f "$EXE_NAME" >/dev/null 2>&1; then launched=1; break; fi
  sleep 0.5
done

# Quit whether or not we confirmed it (don't leave a window around on the runner).
osascript -e "tell application \"${NAME%.app}\" to quit" >/dev/null 2>&1 || true
sleep 1
pkill -f "$EXE_NAME" >/dev/null 2>&1 || true

if [ "$launched" != 1 ]; then
  echo "::error::$NAME did not launch from the installed bundle"
  exit 1
fi
echo "✓ macOS install + launch succeeded for $NAME"
