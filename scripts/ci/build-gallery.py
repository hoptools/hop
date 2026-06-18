#!/usr/bin/env python3
# Copyright 2026
# SPDX-License-Identifier: MPL-2.0
#
# Build a static HTML gallery from the per-job screenshot artifacts and emit it (with the images) into an
# output directory ready to publish to GitHub Pages. Each playground shows every platform/backend
# side-by-side, so you can eyeball cross-toolkit parity at a glance.
#
#   Usage: build-gallery.py <artifacts_dir> <output_dir> [--title T] [--subtitle S] [--source PATH]
#
# <artifacts_dir> holds one subdirectory per downloaded artifact (screenshots-macos/, screenshots-linux-gtk/,
# screenshots-windows-qt/, …), each containing <toolkit>__<playground>.png files. <output_dir> gets an
# index.html plus an images/ folder.

import sys, os, re, shutil, html

# artifact (CI job) name -> human platform label
JOB_PLATFORM = {
    "screenshots-macos": "macOS",
    "screenshots-linux-gtk": "Linux",
    "screenshots-linux-qt": "Linux",
    "screenshots-windows-qt": "Windows",
    "screenshots-windows-winui": "Windows",
}
TOOLKIT_NAME = {"appkit": "AppKit", "swiftui": "SwiftUI", "gtk4": "GTK4", "qt": "Qt", "winui": "WinUI"}
# Stable left-to-right (then top-to-bottom, in the 2-col grid) order of the per-playground variants.
VARIANT_ORDER = [("macOS", "swiftui"), ("macOS", "appkit"), ("macOS", "qt"), ("macOS", "gtk4"),
                 ("Linux", "qt"), ("Linux", "gtk4"), ("Windows", "qt"), ("Windows", "winui")]


def prettify(pg):
    """camelCase playground id -> 'Title Case' heading."""
    spaced = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", pg)
    return spaced[:1].upper() + spaced[1:]


def playground_order(source):
    """The order the playgrounds appear in the demo's `enum Playground` (so the gallery matches the app)."""
    try:
        text = open(source, encoding="utf-8").read()
    except OSError:
        return []
    m = re.search(r"enum Playground: String.*?(?=var title)", text, re.S)
    if not m:
        return []
    ids = []
    for line in m.group(0).splitlines():
        line = line.strip()
        if line.startswith("case "):
            for tok in line[5:].split("//")[0].split(","):
                tok = tok.strip()
                if tok:
                    ids.append(tok)
    return ids


def variant_rank(platform, toolkit):
    try:
        return VARIANT_ORDER.index((platform, toolkit))
    except ValueError:
        return len(VARIANT_ORDER)


def main():
    pos, opts = [], {}
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] in ("--title", "--subtitle", "--source", "--run-url"):
            opts[args[i].lstrip("-")] = args[i + 1]; i += 2
        else:
            pos.append(args[i]); i += 1
    if len(pos) < 2:
        print("usage: build-gallery.py <artifacts_dir> <output_dir> [--title T] [--subtitle S] [--source PATH]",
              file=sys.stderr)
        sys.exit(2)
    artifacts, outdir = pos[0], pos[1]
    title = opts.get("title", "HopUI — Playground Screenshots")
    subtitle = opts.get("subtitle", "")
    source = opts.get("source", "Demos/Showcase/Shared/ContentView.swift")

    # Link back to the exact CI run (and commit) that produced these shots — from the Actions env vars,
    # overridable with --run-url for local testing.
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    sha = os.environ.get("GITHUB_SHA", "")
    run_url = opts.get("run-url") or (f"{server}/{repo}/actions/runs/{run_id}" if repo and run_id else "")
    commit_url = f"{server}/{repo}/commit/{sha}" if repo and sha else ""

    imgdir = os.path.join(outdir, "images")
    os.makedirs(imgdir, exist_ok=True)

    # playground id -> { (platform, toolkit): relative image path }
    shots = {}
    for job in sorted(os.listdir(artifacts)) if os.path.isdir(artifacts) else []:
        jobpath = os.path.join(artifacts, job)
        if not os.path.isdir(jobpath):
            continue
        platform = JOB_PLATFORM.get(job, job)
        for fn in sorted(os.listdir(jobpath)):
            if not fn.endswith(".png") or "__" not in fn:
                continue
            toolkit, pg = fn[:-4].split("__", 1)
            flat = f"{job}__{fn}"
            shutil.copy(os.path.join(jobpath, fn), os.path.join(imgdir, flat))
            shots.setdefault(pg, {})[(platform, toolkit)] = f"images/{flat}"

    order = playground_order(source)
    pgs = [p for p in order if p in shots] + [p for p in sorted(shots) if p not in order]
    total = sum(len(v) for v in shots.values())
    # Each shown playground is expected on every variant; count the ones that didn't get produced.
    missing = sum(1 for pg in pgs for v in VARIANT_ORDER if v not in shots[pg])

    out = []
    out.append("<!doctype html><html lang='en'><head><meta charset='utf-8'>")
    out.append("<meta name='viewport' content='width=device-width, initial-scale=1'>")
    out.append(f"<title>{html.escape(title)}</title>")
    out.append("""<style>
:root { color-scheme: light dark; --bg:#0b0c0f; --card:#16181d; --fg:#e8eaed; --muted:#9aa0a6; --line:#2a2d34; }
* { box-sizing: border-box; }
body { margin:0; font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;
       background:var(--bg); color:var(--fg); }
header { padding:32px 24px 8px; }
h1 { margin:0 0 4px; font-size:24px; }
.sub { color:var(--muted); }
.sub a, footer a { color:var(--fg); text-decoration:none; }
.sub a:hover, footer a:hover { text-decoration:underline; }
nav { position:sticky; top:0; background:var(--bg); border-bottom:1px solid var(--line);
      padding:10px 24px; display:flex; flex-wrap:wrap; gap:6px 12px; font-size:13px; }
nav a { color:var(--muted); text-decoration:none; }
nav a:hover { color:var(--fg); }
section { padding:24px; border-top:1px solid var(--line); }
h2 { margin:0 0 16px; font-size:18px; }
/* Always two columns; each cell (and its screenshot) grows with the window. minmax(0,1fr) lets cells
   shrink below the image's intrinsic width instead of overflowing the grid. */
.row { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:18px; }
figure { margin:0; min-width:0; background:var(--card); border:1px solid var(--line);
         border-radius:10px; overflow:hidden; }
figure img { display:block; width:100%; height:auto; background:#fff; }
/* Placeholder shown when an expected screenshot is missing, so the platform columns stay aligned. */
.blank { display:flex; align-items:center; justify-content:center; width:100%; aspect-ratio:4/3;
         background:#fff; color:#8a8f98; font-size:13px; }
figure.missing { opacity:.85; }
figcaption { padding:8px 12px; font-size:13px; color:var(--muted); }
figcaption b { color:var(--fg); font-weight:600; }
figcaption .na { color:var(--muted); font-style:italic; }
footer { padding:24px; color:var(--muted); font-size:13px; border-top:1px solid var(--line); }
a.full { color:inherit; text-decoration:none; }
</style>""")
    out.append("</head><body>")
    out.append("<header>")
    out.append(f"<h1>{html.escape(title)}</h1>")
    sub_html = html.escape(subtitle) if subtitle else f"{total} screenshots · {len(pgs)} playgrounds"
    if not subtitle and missing:
        sub_html += f" · {missing} missing"
    if run_url:
        label = f"CI run #{html.escape(run_id)}" if run_id else "CI run"
        sub_html += f" · <a href='{html.escape(run_url)}'>{label}</a>"
        if commit_url:
            sub_html += f" · <a href='{html.escape(commit_url)}'>{html.escape(sha[:7])}</a>"
    out.append(f"<div class='sub'>{sub_html}</div>")
    out.append("</header>")

    # quick-jump nav
    out.append("<nav>")
    out.append(" ".join(f"<a href='#{html.escape(p)}'>{html.escape(prettify(p))}</a>" for p in pgs))
    out.append("</nav>")

    for pg in pgs:
        present = shots[pg]
        # Render every EXPECTED variant in the fixed order so the platform/toolkit columns line up across
        # playgrounds; a missing one becomes a blank placeholder rather than collapsing the grid. Any present
        # variant not in the expected set is appended afterwards (defensive — shouldn't normally happen).
        extras = sorted((k for k in present if k not in VARIANT_ORDER), key=lambda k: variant_rank(*k))
        slots = list(VARIANT_ORDER) + extras
        out.append(f"<section id='{html.escape(pg)}'><h2>{html.escape(prettify(pg))}</h2><div class='row'>")
        for (platform, toolkit) in slots:
            tk = TOOLKIT_NAME.get(toolkit, toolkit)
            cap = f"<b>{html.escape(platform)}</b> · {html.escape(tk)}"
            alt = f"{prettify(pg)} on {platform} {tk}"
            rel = present.get((platform, toolkit))
            if rel:
                out.append(
                    f"<figure><a class='full' href='{html.escape(rel)}'>"
                    f"<img loading='lazy' src='{html.escape(rel)}' alt='{html.escape(alt)}'>"
                    f"</a><figcaption>{cap}</figcaption></figure>")
            else:
                out.append(
                    f"<figure class='missing'>"
                    f"<div class='blank' role='img' aria-label='{html.escape(alt)} — not available'>not available</div>"
                    f"<figcaption>{cap} · <span class='na'>missing</span></figcaption></figure>")
        out.append("</div></section>")

    foot = "Generated by scripts/ci/build-gallery.py"
    if run_url:
        foot += f" · <a href='{html.escape(run_url)}'>{html.escape(run_url)}</a>"
    out.append(f"<footer>{foot}</footer>")
    out.append("</body></html>")

    with open(os.path.join(outdir, "index.html"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print(f"Gallery: {len(pgs)} playgrounds, {total} screenshots, {missing} missing -> {outdir}/index.html")


if __name__ == "__main__":
    main()
