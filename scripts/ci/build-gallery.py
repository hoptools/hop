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
# <artifacts_dir> holds one subdirectory per downloaded artifact (screenshots-macos-appkit/,
# screenshots-linux-gtk/, screenshots-windows-qt/, …), each containing <toolkit>__<playground>.png files.
# <output_dir> gets an index.html plus an images/ folder.

import sys, os, re, shutil, html, hashlib

# Map a downloaded artifact's directory name to a human platform label. Artifacts are named
# "screenshots-<os>-<toolkit>" — one per CI job (e.g. screenshots-macos-appkit, screenshots-linux-gtk,
# screenshots-windows-qt). We DERIVE the platform from the <os> segment rather than listing every job:
# the macOS job was split into four per-toolkit jobs (screenshots-macos-appkit/-swiftui/-gtk/-qt), and a
# hardcoded "screenshots-macos" entry then matched none of them — orphaning the macOS shots into bogus
# extra groups while the real macOS slots showed "missing". Deriving the OS keeps that from recurring.
OS_LABEL = {"macos": "macOS", "linux": "Linux", "windows": "Windows"}


def job_platform(job):
    """Artifact dir name 'screenshots-<os>-<toolkit>' -> platform label (falls back to the raw name)."""
    m = re.match(r"screenshots-([a-z]+)", job)
    return OS_LABEL.get(m.group(1), job) if m else job


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


# ---- installers (downloadable app packages) -------------------------------------------------------
# The packaging jobs upload one artifact per platform/toolkit (artifact name == filename), e.g.
# hopdemo-macos-aarch64-appkit.dmg / hopdemo-linux-x86_64-qt.flatpak / hopdemo-windows-x86_64-winui.msix.
# We copy them into the published site (downloads/) so the links resolve, with a verifiable checksum.
INSTALLER_EXTS = (".dmg", ".flatpak", ".msix", ".appimage", ".zip", ".exe", ".pkg")
INSTALLER_OS_ORDER = {"macos": 0, "linux": 1, "windows": 2}
TOOLKIT_ORDER = {"swiftui": 0, "appkit": 1, "gtk4": 2, "qt": 3, "winui": 4}
FORMAT_LABEL = {"dmg": "Disk image (.dmg)", "flatpak": "Flatpak (.flatpak)", "msix": "MSIX (.msix)",
                "appimage": "AppImage", "pkg": "Installer (.pkg)", "zip": "Zip archive", "exe": "Installer (.exe)"}


def human_size(n):
    """Bytes -> human-readable, e.g. 1536 -> '1.5 KB'."""
    size = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{int(size)} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def installer_meta(fn):
    """hopdemo-<os>-<arch>-<toolkit>.<ext> -> (platform_label, toolkit_label, format_label, sortkey)."""
    m = re.match(r"hopdemo-([a-z0-9]+)-([a-z0-9_]+)-([a-z0-9]+)\.(.+)$", fn)
    if not m:
        return (fn, "", fn.rsplit(".", 1)[-1] if "." in fn else "", (9, 9, fn))
    osid, arch, tk, ext = m.groups()
    plat = f"{OS_LABEL.get(osid, osid)} · {arch}"
    sortkey = (INSTALLER_OS_ORDER.get(osid, 9), TOOLKIT_ORDER.get(tk, 9), fn)
    return (plat, TOOLKIT_NAME.get(tk, tk), FORMAT_LABEL.get(ext, ext), sortkey)


def collect_installers(installers_dir, outdir):
    """Find installer files under installers_dir (recursively — download-artifact may nest per artifact),
    copy each into outdir/downloads/, and return a list sorted by platform/toolkit with size + sha256."""
    found, seen = [], set()
    if not installers_dir or not os.path.isdir(installers_dir):
        return found
    dldir = os.path.join(outdir, "downloads")
    for root, _, files in os.walk(installers_dir):
        for fn in files:
            if not fn.lower().endswith(INSTALLER_EXTS) or fn in seen:
                continue
            seen.add(fn)
            src = os.path.join(root, fn)
            os.makedirs(dldir, exist_ok=True)
            shutil.copy(src, os.path.join(dldir, fn))
            found.append({"file": fn, "rel": f"downloads/{fn}",
                          "size": os.path.getsize(src), "sha256": sha256_of(src)})
    found.sort(key=lambda it: installer_meta(it["file"])[3])
    return found


def main():
    pos, opts = [], {}
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] in ("--title", "--subtitle", "--source", "--run-url", "--installers"):
            opts[args[i].lstrip("-")] = args[i + 1]; i += 2
        else:
            pos.append(args[i]); i += 1
    if len(pos) < 2:
        print("usage: build-gallery.py <artifacts_dir> <output_dir> [--title T] [--subtitle S] "
              "[--source PATH] [--installers DIR]", file=sys.stderr)
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
        platform = job_platform(job)
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

    # Installers (copied into outdir/downloads/ with size + checksum) for the bottom-of-page download table.
    installers = collect_installers(opts.get("installers"), outdir)

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
/* The quick-jump nav sticks to the top while scrolling, so it needs a solid, opaque background and a
   z-index above the screenshots — otherwise the links render straight over a screenshot and become
   unreadable. The shadow separates the bar from the content scrolling underneath it. */
nav { position:sticky; top:0; z-index:20; background:var(--bg); border-bottom:1px solid var(--line);
      box-shadow:0 2px 10px rgba(0,0,0,.5);
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
/* Downloads table: installers for each platform/toolkit, with size + verifiable SHA-256. */
table.downloads { width:100%; border-collapse:collapse; font-size:13px; }
table.downloads th, table.downloads td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line);
                                          vertical-align:top; }
table.downloads th { color:var(--muted); font-weight:600; white-space:nowrap; }
table.downloads td.num { white-space:nowrap; color:var(--muted); }
table.downloads a { color:var(--fg); font-weight:600; }
code.sha { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size:11px;
           color:var(--muted); word-break:break-all; }
</style>""")
    out.append("</head><body>")
    out.append("<header>")
    out.append(f"<h1>{html.escape(title)}</h1>")
    sub_html = html.escape(subtitle) if subtitle else f"{total} screenshots · {len(pgs)} playgrounds"
    if not subtitle and missing:
        sub_html += f" · {missing} missing"
    if not subtitle and installers:
        sub_html += f" · <a href='#downloads'>{len(installers)} downloads</a>"
    if run_url:
        label = f"CI run #{html.escape(run_id)}" if run_id else "CI run"
        sub_html += f" · <a href='{html.escape(run_url)}'>{label}</a>"
        if commit_url:
            sub_html += f" · <a href='{html.escape(commit_url)}'>{html.escape(sha[:7])}</a>"
    out.append(f"<div class='sub'>{sub_html}</div>")
    out.append("</header>")

    # quick-jump nav
    out.append("<nav>")
    nav_links = [f"<a href='#{html.escape(p)}'>{html.escape(prettify(p))}</a>" for p in pgs]
    if installers:
        nav_links.append("<a href='#downloads'>Downloads</a>")
    out.append(" ".join(nav_links))
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

    # Downloads: every platform/toolkit installer this build produced, hosted alongside the page, with file
    # size and a SHA-256 checksum for verification.
    if installers:
        out.append("<section id='downloads'><h2>Downloads</h2>")
        out.append("<div class='sub'>Demo-app installers from this build — verify with the SHA-256 checksum "
                   "(e.g. <code class='sha'>shasum -a 256 &lt;file&gt;</code>).</div>")
        out.append("<table class='downloads'><thead><tr>"
                   "<th>Platform</th><th>Toolkit</th><th>Format</th><th>File</th><th>Size</th><th>SHA-256</th>"
                   "</tr></thead><tbody>")
        for it in installers:
            plat, tk, fmt, _ = installer_meta(it["file"])
            out.append(
                "<tr>"
                f"<td>{html.escape(plat)}</td>"
                f"<td>{html.escape(tk)}</td>"
                f"<td>{html.escape(fmt)}</td>"
                f"<td><a href='{html.escape(it['rel'])}' download>{html.escape(it['file'])}</a></td>"
                f"<td class='num'>{human_size(it['size'])}</td>"
                f"<td><code class='sha'>{it['sha256']}</code></td>"
                "</tr>")
        out.append("</tbody></table></section>")

    foot = "Generated by scripts/ci/build-gallery.py"
    if run_url:
        foot += f" · <a href='{html.escape(run_url)}'>{html.escape(run_url)}</a>"
    out.append(f"<footer>{foot}</footer>")
    out.append("</body></html>")

    with open(os.path.join(outdir, "index.html"), "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print(f"Gallery: {len(pgs)} playgrounds, {total} screenshots, {missing} missing, "
          f"{len(installers)} installers -> {outdir}/index.html")


if __name__ == "__main__":
    main()
