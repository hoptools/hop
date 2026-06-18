#!/usr/bin/env bash
# Build and launch the HopUI demo app against a chosen toolkit paradigm.
#
# Usage: scripts/run_demo.sh <gtk4|appkit|qt|swiftui|all>
#
#   gtk4     GTK4 toolkit      (macOS/Linux/Windows; needs GTK4 — macOS: `brew install gtk4`)
#   appkit   AppKit toolkit    (macOS only)
#   qt       Qt6 toolkit       (macOS; needs Homebrew Qt6 — `brew install qt`)
#   swiftui  Apple SwiftUI     (macOS only; the same ContentView built against real SwiftUI)
#   all      build everything, then launch all four side by side
#
# A single paradigm runs in the foreground via `swift run`. `all` builds once, launches the four
# prebuilt binaries concurrently in the background, and stays attached so Ctrl-C stops them all.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    echo "Usage: $(basename "$0") <gtk4|appkit|qt|swiftui|all>" >&2
    exit 2
}

[ $# -eq 1 ] || usage

# The demo apps live in their own package now; build/run them there (it depends on the root package and on
# the standalone HopUIComboBox component package).
SHOWCASE="Demos/Apps/Showcase"

# Map each paradigm to its SwiftPM executable target.
exec_for() {
    case "$1" in
        gtk4)    echo "hop-demo-gtk4" ;;
        appkit)  echo "hop-demo-appkit" ;;
        qt)      echo "hop-demo-qt" ;;
        swiftui) echo "hop-demo-native" ;;
        *) return 1 ;;
    esac
}

case "${1:-}" in
    gtk4|appkit|qt|swiftui)
        exec swift run --package-path "$SHOWCASE" "$(exec_for "$1")"
        ;;
    all)
        echo "Building all demo executables…"
        swift build --package-path "$SHOWCASE"
        bin="$(swift build --package-path "$SHOWCASE" --show-bin-path)"

        pids=()
        for paradigm in gtk4 appkit qt swiftui; do
            target="$(exec_for "$paradigm")"
            log="/tmp/hop-demo-$paradigm.log"
            echo "Launching $paradigm ($target) → $log"
            "$bin/$target" >"$log" 2>&1 &
            pids+=($!)
        done

        echo "All four demos launched (pids: ${pids[*]})."
        echo "Press Ctrl-C to stop them all."
        # Stop every child on interrupt/terminate, then wait so this stays attached to them.
        trap 'echo; echo "Stopping demos…"; kill "${pids[@]}" 2>/dev/null || true' INT TERM
        wait
        ;;
    *)
        usage
        ;;
esac
