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
    sed -n '/enum Playground: String/,/var title/p' Demo/ContentView.swift \
        | grep -E '^[[:space:]]*case ' \
        | sed -E 's@//.*@@; s/^[[:space:]]*case //' \
        | tr ',' '\n' \
        | sed -E 's/[[:space:]]//g' \
        | grep .
}

BIN="$(swift build --show-bin-path)"
PGS=()
while IFS= read -r p; do PGS+=("$p"); done < <(playgrounds)
[ "${#PGS[@]}" -gt 0 ] || { echo "no playgrounds parsed from Demo/ContentView.swift" >&2; exit 2; }
echo "Backends: ${TOOLKITS[*]}"
echo "Playgrounds (${#PGS[@]}): ${PGS[*]}"
echo "Binaries:  $BIN"

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
        Xvfb "$DISPLAY" -screen 0 1100x900x24 -nolisten tcp >/tmp/hop-xvfb.log 2>&1 &
        XVFB_PID=$!
        trap '[ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true' EXIT
        for _ in $(seq 1 40); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.25; done
    fi
    # Force software rendering so GTK4/Qt render without a GPU on the virtual display.
    export GDK_BACKEND=x11 GSK_RENDERER=cairo
    export QT_QPA_PLATFORM=xcb QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/hop-xdg}"; mkdir -p "$XDG_RUNTIME_DIR"

    capture_one() {  # <exe> <playground> <outfile>
        local exe="$1" pg="$2" out="$3"
        HOP_PLAYGROUND_ID="$pg" "$BIN/$exe" >/dev/null 2>&1 &
        local pid=$!
        sleep 4   # give the window time to map + draw (no WM; we capture the root)
        # ImageMagick 6 uses `import`/`convert`; IM7 uses `magick import`/`magick`. Try both, then xwd.
        import -display "$DISPLAY" -window root "$out" 2>/dev/null \
            || magick import -display "$DISPLAY" -window root "$out" 2>/dev/null \
            || { xwd -root -display "$DISPLAY" -silent 2>/dev/null | convert xwd:- "$out" 2>/dev/null; } \
            || { xwd -root -display "$DISPLAY" -silent 2>/dev/null | magick xwd:- "$out" 2>/dev/null; }
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        [ -s "$out" ]
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
