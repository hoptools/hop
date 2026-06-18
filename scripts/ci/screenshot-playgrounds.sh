#!/usr/bin/env bash
# Launch the HopUI demo for one or more toolkit backends, open each playground in turn, and save a
# screenshot of every page. Used by CI to attach per-backend screenshot artifacts.
#
#   Usage: scripts/ci/screenshot-playgrounds.sh <outdir> <toolkit...>
#     toolkit ∈ appkit | swiftui | gtk4 | qt   (each maps to a `hop-demo-*` executable)
#
# A playground is selected by launching the demo with HOP_PLAYGROUND_ID set (the demo reads it as its
# initial selection), so we relaunch once per playground rather than driving the sidebar. The list of
# playgrounds is the Demo's `Playground` enum — the single source of truth, parsed below.
#
#   macOS: captures the demo's own window (CGWindowList → `screencapture -l<id>`), which works even when
#          the window isn't frontmost.
#   Linux: runs everything under a self-managed Xvfb (software rendering) and captures the X root.
#
# Best-effort: a failed capture is logged but never fails the job (the build/test gate is what matters);
# this script always exits 0. The CI step uploads whatever PNGs were produced.
set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

# The demo apps live in their own package (it depends on the root package + the HopUIComboBox component).
SHOWCASE="Demos/Showcase"

OUTDIR="${1:?usage: screenshot-playgrounds.sh <outdir> <toolkit...>}"; shift || true
[ "$#" -gt 0 ] || { echo "no toolkits given" >&2; exit 2; }
TOOLKITS=("$@")
mkdir -p "$OUTDIR"

# toolkit name → demo executable (mirrors scripts/run_demo.sh).
exec_for() {
    case "$1" in
        gtk4)    echo "hop-demo-gtk4" ;;
        appkit)  echo "hop-demo-appkit" ;;
        qt)      echo "hop-demo-qt" ;;
        swiftui) echo "hop-demo-native" ;;
        *) return 1 ;;
    esac
}

# The playground ids = the cases of `enum Playground: String` in the shared demo ContentView.
playgrounds() {
    sed -n '/enum Playground: String/,/var title/p' "$SHOWCASE/Shared/ContentView.swift" \
        | grep -E '^[[:space:]]*case ' \
        | sed -E 's@//.*@@; s/^[[:space:]]*case //' \
        | tr ',' '\n' \
        | sed -E 's/[[:space:]]//g' \
        | grep .
}

swift build --package-path "$SHOWCASE" >&2 || { echo "Showcase build failed" >&2; exit 0; }
BIN="$(swift build --package-path "$SHOWCASE" --show-bin-path)"
PGS=()
while IFS= read -r p; do PGS+=("$p"); done < <(playgrounds)
[ "${#PGS[@]}" -gt 0 ] || { echo "no playgrounds parsed from $SHOWCASE/Shared/ContentView.swift" >&2; exit 2; }
echo "Backends: ${TOOLKITS[*]}"
echo "Playgrounds (${#PGS[@]}): ${PGS[*]}"
echo "Binaries:  $BIN"

# Uniform window size for screenshots — each backend's primary window honors HOP_WINDOW_SIZE (see
# hopRequestedWindowSize() / HopDemoApp's .defaultSize). 1280x800 is the standard Mac marketing size.
export HOP_WINDOW_SIZE="${HOP_WINDOW_SIZE:-1280x800}"
echo "Window size: $HOP_WINDOW_SIZE"

OS="$(uname -s)"

# ---- per-OS capture setup -------------------------------------------------------------------------

if [ "$OS" = "Darwin" ]; then
    WINID="$(mktemp -d)/winid"
    swiftc -O scripts/ci/winid.swift -o "$WINID" || { echo "failed to build winid helper" >&2; exit 0; }

    capture_one() {  # <exe> <playground> <outfile>
        local exe="$1" pg="$2" out="$3"
        HOP_PLAYGROUND_ID="$pg" "$BIN/$exe" >/dev/null 2>&1 &
        local pid=$! id=""
        for _ in $(seq 1 40); do
            sleep 0.25
            id="$("$WINID" "$pid" 2>/dev/null)" || true
            [ -n "$id" ] && break
        done
        sleep 1.0   # let it finish drawing
        if [ -n "$id" ]; then
            screencapture -o -x -l"$id" "$out" 2>/dev/null
        else
            screencapture -o -x "$out" 2>/dev/null   # fallback: whole display
        fi
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        [ -s "$out" ]
    }

elif [ "$OS" = "Linux" ]; then
    export DISPLAY="${DISPLAY:-:99}"
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        # Virtual display larger than the window, so the (undecorated, top-left-mapped) window never clips.
        Xvfb "$DISPLAY" -screen 0 1920x1200x24 -nolisten tcp >/tmp/hop-xvfb.log 2>&1 &
        XVFB_PID=$!
        trap '[ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true' EXIT
        for _ in $(seq 1 40); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.25; done
    fi
    # Force software rendering so GTK4/Qt render without a GPU on the virtual display.
    export GDK_BACKEND=x11 GSK_RENDERER=cairo
    export QT_QPA_PLATFORM=xcb QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/hop-xdg}"; mkdir -p "$XDG_RUNTIME_DIR"

    # The largest top-level window owned by a pid (the app's main window) — via xdotool + _NET_WM_PID.
    largest_window_for_pid() {
        local pid="$1" wid best=0 chosen="" WIDTH HEIGHT area
        for wid in $(xdotool search --pid "$pid" 2>/dev/null); do
            WIDTH=""; HEIGHT=""
            eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)"   # sets WIDTH / HEIGHT / ...
            case "${WIDTH:-x}${HEIGHT:-x}" in *[!0-9]*) continue;; esac
            area=$(( WIDTH * HEIGHT ))
            if [ "$area" -gt "$best" ]; then best="$area"; chosen="$wid"; fi
        done
        echo "$chosen"
    }

    # Capture window $1 to $2 (IM6 `import` / IM7 `magick import`); succeeds only if the result is non-blank
    # (an unrendered window is a single flat color → ~1 unique color; any real page has hundreds).
    grab_window() {  # <wid> <out>
        import -window "$1" "$2" 2>/dev/null || magick import -window "$1" "$2" 2>/dev/null
        [ -s "$2" ] || return 1
        local k; k="$(identify -format '%k' "$2" 2>/dev/null || magick identify -format '%k' "$2" 2>/dev/null)"
        case "$k" in ''|*[!0-9]*) return 1;; esac
        [ "$k" -ge 5 ]
    }

    capture_one() {  # <exe> <playground> <outfile>
        local exe="$1" pg="$2" out="$3"
        HOP_PLAYGROUND_ID="$pg" "$BIN/$exe" >/dev/null 2>&1 &
        local pid=$! wid="" ok=1
        for _ in $(seq 1 40); do sleep 0.25; wid="$(largest_window_for_pid "$pid")"; [ -n "$wid" ] && break; done
        if [ -n "$wid" ]; then
            # Retry until the window has actually drawn content (not a blank/flat first frame).
            for _ in $(seq 1 16); do sleep 0.6; if grab_window "$wid" "$out"; then ok=0; break; fi; done
        fi
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        if [ "$ok" -ne 0 ]; then rm -f "$out"; return 1; fi   # never leave a blank behind
        return 0
    }
else
    echo "unsupported OS: $OS" >&2; exit 0
fi

# ---- capture loop ---------------------------------------------------------------------------------

ok=0; bad=0
for tk in "${TOOLKITS[@]}"; do
    exe="$(exec_for "$tk")" || { echo "unknown toolkit: $tk" >&2; continue; }
    if [ ! -x "$BIN/$exe" ]; then echo "skip $tk: $BIN/$exe not built" >&2; continue; fi
    for pg in "${PGS[@]}"; do
        out="$OUTDIR/${tk}__${pg}.png"
        if capture_one "$exe" "$pg" "$out"; then echo "  ✓ $tk / $pg"; ok=$((ok+1)); else echo "  ✗ $tk / $pg" >&2; bad=$((bad+1)); fi
    done
done

echo "Captured $ok screenshot(s) ($bad failed) → $OUTDIR"
ls -la "$OUTDIR" || true
exit 0   # never fail the job over screenshots
