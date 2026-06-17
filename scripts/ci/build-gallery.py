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
# Stable left-to-right order of the per-playground variants.
VARIANT_ORDER = [("macOS", "appkit"), ("macOS", "swiftui"), ("macOS", "gtk4"), ("macOS", "qt"),
                 ("Linux", "gtk4"), ("Linux", "qt"), ("Windows", "qt"), ("Windows", "winui")]


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
        if args[i] in ("--title", "--subtitle", "--source"):
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
    source = opts.get("source", "Demo/ContentView.swift")

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
nav { position:sticky; top:0; background:var(--bg); border-bottom:1px solid var(--line);
      padding:10px 24px; display:flex; flex-wrap:wrap; gap:6px 12px; font-size:13px; }
nav a { color:var(--muted); text-decoration:none; }
nav a:hover { color:var(--fg); }
section { padding:24px; border-top:1px solid var(--line); }
h2 { margin:0 0 16px; font-size:18px; }
.row { display:flex; flex-wrap:wrap; gap:18px; }
figure { margin:0; width:380px; max-width:100%; background:var(--card); border:1px solid var(--line);
         border-radius:10px; overflow:hidden; }
figure img { display:block; width:100%; height:auto; background:#fff; }
figcaption { padding:8px 12px; font-size:13px; color:var(--muted); }
figcaption b { color:var(--fg); font-weight:600; }
footer { padding:24px; color:var(--muted); font-size:13px; border-top:1px solid var(--line); }
a.full { color:inherit; text-decoration:none; }
</style>""")
    out.append("</head><body>")
    out.append("<header>")
    out.append(f"<h1>{html.escape(title)}</h1>")
    sub = subtitle or f"{total} screenshots · {len(pgs)} playgrounds · captured by CI"
    out.append(f"<div class='sub'>{html.escape(sub)}</div>")
    out.append("</header>")

    # quick-jump nav
    out.append("<nav>")
    out.append(" ".join(f"<a href='#{html.escape(p)}'>{html.escape(prettify(p))}</a>" for p in pgs))
    out.append("</nav>")

    for pg in pgs:
        variants = sorted(shots[pg].items(), key=lambda kv: variant_rank(kv[0][0], kv[0][1]))
        out.append(f"<section id='{html.escape(pg)}'><h2>{html.escape(prettify(pg))}</h2><div class='row'>")
        for (platform, toolkit), rel in variants:
            tk = TOOLKIT_NAME.get(toolkit, toolkit)
            cap = f"<b>{html.escape(platform)}</b> · {html.escape(tk)}"
            out.append(
                f"<figure><a class='full' href='{html.escape(rel)}'>"
                f"<img loading='lazy' src='{html.escape(rel)}' alt='{html.escape(prettify(pg))} on {html.escape(platform)} {html.escape(tk)}'>"
                f"</a><figcaption>{cap}</figcaption></figure>")
        out.append("</div></section>")

    out.append("<footer>Generated by scripts/ci/build-gallery.py</footer>")
    out.append("</body></html>")

    with open(os.path.join(outdir, "index.html"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print(f"Gallery: {len(pgs)} playgrounds, {total} screenshots -> {outdir}/index.html")


if __name__ == "__main__":
    main()
