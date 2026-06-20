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
#          the window isn't frontmost. A background `caffeinate` keeps the (possibly headless) display awake.
#   Linux: runs everything under a self-managed Xvfb (software rendering) and captures the window via xdotool.
#
# Every capture is VALIDATED for content (not just "a file exists"): an unrendered window is one flat color,
# so we count distinct colors and retry until the page has actually drawn — a blank/slow first frame no longer
# slips through as a "successful" but empty screenshot. A persistently-blank or window-less capture is recorded
# as a failure and its file removed, so the published gallery shows "missing" rather than a misleading blank.
#
# A per-screenshot summary (status · dimensions · file size) is written to $GITHUB_STEP_SUMMARY (and stdout)
# so the success/failure of every shot is visible in the CI run.
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

# A captured window is "rendered" once it has at least this many distinct colors. A blank/unrendered window
# is one flat color (plus a few anti-aliased corner pixels on a retina capture); any real HopUI page carries
# the sidebar list + toolbar + text, i.e. hundreds of colors (measured: ~440). 64 sits comfortably between.
# (Overridable via env, mostly for testing the failure path.)
MIN_COLORS="${MIN_COLORS:-64}"
# Per-playground capture budget: retry the grab this many times (× delay) waiting for content to draw.
# Generous, since a software-rendered GTK window on a headless CI display can be slow to paint its first frame
# (OK pages break out as soon as content appears, so this only costs wall-clock on genuine failures).
CAPTURE_TRIES="${CAPTURE_TRIES:-20}"
CAPTURE_DELAY="${CAPTURE_DELAY:-0.6}"

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

# GTK4 defaults to the GPU-backed GL renderer ("ngl"). CI displays — GitHub's headless macOS runners and the
# Xvfb virtual display on Linux — have no usable GPU, so the GL renderer produces a BLANK window (which is why
# the GTK shots were blank/missing in the gallery). Force GTK's software cairo renderer on EVERY OS; it renders
# identically to GL on a real display and is the headless-safe path. Non-GTK toolkits ignore GSK_*.
export GSK_RENDERER="${GSK_RENDERER:-cairo}"

OS="$(uname -s)"

# ---- helpers: human-readable size, summary state --------------------------------------------------

SUMMARY_ROWS=()                                   # markdown table rows, one per attempted screenshot
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"           # GitHub Actions step-summary file (empty when run locally)

# Human-readable byte size (integer math, one decimal — no awk dependency).
human_size() {
    local b="${1:-0}"
    if   [ "$b" -ge 1048576 ]; then echo "$((b/1048576)).$(((b%1048576)*10/1048576)) MB"
    elif [ "$b" -ge 1024 ];    then echo "$((b/1024)).$(((b%1024)*10/1024)) KB"
    else echo "${b} B"; fi
}

# Byte size of a file (BSD `stat -f%z` / GNU `stat -c%s`).
file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# ---- per-OS capture setup -------------------------------------------------------------------------
# Each OS defines three primitives that the common capture_one() drives:
#   launch_demo <exe> <pg>   -> starts the demo in the background; sets global DEMO_PID
#   find_window <pid>        -> echoes an opaque window handle for that pid (empty if none yet)
#   grab <handle> <outfile>  -> best-effort capture of that window to outfile (0 if bytes were written)
# plus `img_stat <file>` echoing "<w> <h> <colors>".

cleanup() {
    [ -n "${CAFFEINATE_PID:-}" ] && kill "$CAFFEINATE_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ]       && kill "$XVFB_PID"       2>/dev/null || true
}
trap cleanup EXIT

if [ "$OS" = "Darwin" ]; then
    WINID="$(mktemp -d)/winid"
    swiftc -O scripts/ci/winid.swift -o "$WINID" || { echo "failed to build winid helper" >&2; exit 0; }
    # Dependency-free image stats (GitHub's macOS runners have no ImageMagick). If it fails to build, fall
    # back to a sentinel high color count so captures still succeed (degraded: no dimensions / blank check).
    IMGSTAT="$(mktemp -d)/imgstat"
    swiftc -O scripts/ci/imgstat.swift -o "$IMGSTAT" 2>/dev/null || IMGSTAT=""
    img_stat() { [ -n "$IMGSTAT" ] && "$IMGSTAT" "$1" 2>/dev/null || echo "0 0 999999"; }

    # Keep the (possibly headless / asleep) display awake for the whole run so screencapture sees real pixels.
    caffeinate -d -i -u >/dev/null 2>&1 &
    CAFFEINATE_PID=$!

    launch_demo() { HOP_PLAYGROUND_ID="$2" "$BIN/$1" >/dev/null 2>&1 & DEMO_PID=$!; }
    find_window() { "$WINID" "$1" 2>/dev/null || true; }
    grab() { screencapture -o -x -l"$1" "$2" 2>/dev/null; [ -s "$2" ]; }

elif [ "$OS" = "Linux" ]; then
    export DISPLAY="${DISPLAY:-:99}"
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        # Virtual display larger than the window, so the (undecorated, top-left-mapped) window never clips.
        Xvfb "$DISPLAY" -screen 0 1920x1200x24 -nolisten tcp >/tmp/hop-xvfb.log 2>&1 &
        XVFB_PID=$!
        for _ in $(seq 1 40); do xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break; sleep 0.25; done
    fi
    # Force software rendering so GTK4/Qt render without a GPU on the virtual display (GTK via GSK_RENDERER
    # above; Qt/GL via the flags below).
    export GDK_BACKEND=x11
    export QT_QPA_PLATFORM=xcb QT_OPENGL=software LIBGL_ALWAYS_SOFTWARE=1
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/hop-xdg}"; mkdir -p "$XDG_RUNTIME_DIR"

    img_stat() {  # "<w> <h> <colors>" via ImageMagick (IM6 `identify` / IM7 `magick identify`)
        local s
        s="$(identify -format '%w %h %k' "$1" 2>/dev/null || magick identify -format '%w %h %k' "$1" 2>/dev/null)"
        echo "${s:-0 0 0}"
    }

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

    launch_demo() { HOP_PLAYGROUND_ID="$2" "$BIN/$1" >/dev/null 2>&1 & DEMO_PID=$!; }
    find_window() { largest_window_for_pid "$1"; }
    grab() { import -window "$1" "$2" 2>/dev/null || magick import -window "$1" "$2" 2>/dev/null; [ -s "$2" ]; }
else
    echo "unsupported OS: $OS" >&2; exit 0
fi

# ---- common capture: launch, wait for window, retry until content drawn ----------------------------

# Echoes a status word: ok | blank | nowindow. Leaves the last captured bytes at <out> (even on blank) so the
# caller can report its dimensions/size before deciding whether to keep it.
capture_one() {  # <exe> <playground> <outfile>
    local exe="$1" pg="$2" out="$3"
    rm -f "$out"
    launch_demo "$exe" "$pg"
    local pid="$DEMO_PID" win="" status="nowindow" i w h k
    for i in $(seq 1 40); do
        sleep 0.25
        win="$(find_window "$pid")" || true
        [ -n "$win" ] && break
    done
    if [ -n "$win" ]; then
        status="blank"
        for i in $(seq 1 "$CAPTURE_TRIES"); do
            sleep "$CAPTURE_DELAY"
            grab "$win" "$out" || continue
            read -r w h k < <(img_stat "$out")
            if [ "${k:-0}" -ge "$MIN_COLORS" ]; then status="ok"; break; fi
        done
    fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    echo "$status"
}

# ---- capture loop ---------------------------------------------------------------------------------

ok=0; bad=0
for tk in "${TOOLKITS[@]}"; do
    exe="$(exec_for "$tk")" || { echo "unknown toolkit: $tk" >&2; continue; }
    if [ ! -x "$BIN/$exe" ]; then echo "skip $tk: $BIN/$exe not built" >&2; continue; fi
    for pg in "${PGS[@]}"; do
        out="$OUTDIR/${tk}__${pg}.png"
        status="$(capture_one "$exe" "$pg" "$out")"

        # Measure whatever we captured (even a blank) so the summary always carries dimensions + size.
        dims="—"; size="—"
        if [ -f "$out" ]; then
            read -r w h _ < <(img_stat "$out")
            [ "${w:-0}" -gt 0 ] && dims="${w}×${h}"
            size="$(human_size "$(file_size "$out")")"
        fi

        if [ "$status" = "ok" ]; then
            echo "  ✓ $tk / $pg  ($dims, $size)"; ok=$((ok+1))
            SUMMARY_ROWS+=("| \`$tk\` | \`$pg\` | ✅ ok | $dims | $size |")
        else
            echo "  ✗ $tk / $pg  ($status; $dims, $size)" >&2; bad=$((bad+1))
            SUMMARY_ROWS+=("| \`$tk\` | \`$pg\` | ❌ $status | $dims | $size |")
            rm -f "$out"   # never leave a blank/failed shot in the gallery — let it show as "missing"
        fi
    done
done

# ---- summary (stdout + $GITHUB_STEP_SUMMARY) ------------------------------------------------------

{
    echo "### Screenshots — ${TOOLKITS[*]} (${OS})"
    echo ""
    echo "✅ **${ok}** captured · ❌ **${bad}** failed · ${#PGS[@]} playground(s) × ${#TOOLKITS[@]} toolkit(s)"
    echo ""
    echo "| Toolkit | Playground | Status | Dimensions | Size |"
    echo "| --- | --- | --- | --- | ---: |"
    for row in "${SUMMARY_ROWS[@]}"; do echo "$row"; done
} | tee /tmp/hop-screenshot-summary.md

[ -n "$SUMMARY_FILE" ] && cat /tmp/hop-screenshot-summary.md >> "$SUMMARY_FILE" || true

echo "Captured $ok screenshot(s) ($bad failed) → $OUTDIR"
ls -la "$OUTDIR" || true
exit 0   # never fail the job over screenshots
