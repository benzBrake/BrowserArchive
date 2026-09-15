#!/usr/bin/env bash
# Scrape the latest Brave / Brave Origin Windows installer links per channel
# from https://versions.brave.com/latest/brave-versions.json and write
# data/brave.json + data/brave-origin.json (links only, no downloads).
# Env: PROXY (optional, for local debugging)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${PROXY:-}" ]]; then
  export https_proxy="$PROXY" http_proxy="$PROXY"
fi

PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --no-project python' || echo 'python3')"

$PY - <<'EOF'
import datetime, json, os, urllib.request

URL = "https://versions.brave.com/latest/brave-versions.json"
CHANNELS = {"release": "stable", "beta": "beta", "nightly": "nightly", "dev": "dev"}
CAPS = {"stable": "", "beta": "Beta", "nightly": "Nightly", "dev": "Dev"}
# arch -> (installer filename suffix, zip arch fragment); standalone = full
# offline installer, nightly/dev ship zips instead of branded installers
WANTED = {
    "x64": ("Setup.exe", "win32-x64"),
    "x86": ("Setup32.exe", "win32-ia32"),
    "arm64": ("SetupArm64.exe", "win32-arm64"),
}
# one output file per product flavor; Brave Origin is a separate product
# shipped in the same releases with parallel asset names
PRODUCTS = [
    {"name": "Brave", "file": "brave.json", "prefix": "BraveBrowserStandalone", "zip": "brave-v"},
    {"name": "Brave Origin", "file": "brave-origin.json", "prefix": "BraveOriginStandalone", "zip": "brave-origin-v"},
]

with urllib.request.urlopen(URL, timeout=60) as resp:
    data = json.load(resp)

def wanted_files(release, channel, prefix, zip_prefix):
    cap = CAPS[channel]
    assets = {a["name"]: a["download_url"] for a in release["github"]["assets"]}
    files = {}
    for arch, (suffix, zip_arch) in WANTED.items():
        filename = f"{prefix}{cap}{suffix}"
        url = assets.get(filename)
        if not url:  # nightly/dev ship zips instead of branded installers
            filename = f"{zip_prefix}{release['name']}-{zip_arch}.zip"
            url = assets.get(filename)
        if url:
            files[arch] = {"filename": filename, "url": url}
    return files


def latest_channels(prefix, zip_prefix):
    # latest release per channel that actually ships Windows packages
    best = {}
    for release in data.values():
        channel = CHANNELS.get(release["channel"])
        if not channel:
            continue
        files = wanted_files(release, channel, prefix, zip_prefix)
        if not files:
            continue  # no Windows assets (e.g. newest nightly still uploading)
        if channel not in best or release["published"] > best[channel][0]["published"]:
            best[channel] = (release, files)
    return best


def build_document(product):
    channels = {}
    for channel, (release, files) in latest_channels(product["prefix"], product["zip"]).items():
        channels[channel] = {
            "version": release["name"],
            "published": release["published"],
            "chrome": release["dependencies"]["chrome"],
            "files": files,
        }
    if "stable" not in channels:
        raise SystemExit(f"no Windows installers found for {product['name']} stable, aborting")
    return {
        "name": product["name"],
        "version": channels["stable"]["version"],
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "source": URL,
        "channels": {c: channels[c] for c in ("stable", "beta", "nightly", "dev") if c in channels},
    }


os.makedirs(os.path.join(os.environ["REPO_DIR"], "data"), exist_ok=True)
for product in PRODUCTS:
    out = build_document(product)
    path = os.path.join(os.environ["REPO_DIR"], "data", product["file"])
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{product['file']} written: stable={out['version']}, channels={list(out['channels'])}")
EOF
