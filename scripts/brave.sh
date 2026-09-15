#!/usr/bin/env bash
# Scrape the latest Brave Windows installer links per channel from
# https://versions.brave.com/latest/brave-versions.json and write data/brave.json
# (links only, no downloads).
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
# arch -> installer filename fragments (standalone = full offline installer);
# nightly/dev ship zips instead of branded installers, keyed by zip arch suffix
WANTED = {
    "x64": ("BraveBrowserStandaloneSetup.exe", "BraveBrowserStandalone{cap}Setup.exe", "win32-x64"),
    "x86": ("BraveBrowserStandaloneSetup32.exe", "BraveBrowserStandalone{cap}Setup32.exe", "win32-ia32"),
    "arm64": ("BraveBrowserStandaloneSetupArm64.exe", "BraveBrowserStandalone{cap}SetupArm64.exe", "win32-arm64"),
}

with urllib.request.urlopen(URL, timeout=60) as resp:
    data = json.load(resp)

def wanted_files(release, channel):
    cap = {"stable": "", "beta": "Beta", "nightly": "Nightly", "dev": "Dev"}[channel]
    assets = {a["name"]: a["download_url"] for a in release["github"]["assets"]}
    files = {}
    for arch, (stable_name, tpl_name, zip_arch) in WANTED.items():
        filename = stable_name if channel == "stable" else tpl_name.format(cap=cap)
        url = assets.get(filename)
        if not url:  # nightly/dev ship zips instead of branded installers
            filename = f"brave-v{release['name']}-{zip_arch}.zip"
            url = assets.get(filename)
        if url:
            files[arch] = {"filename": filename, "url": url}
    return files


# latest release per channel that actually ships Windows packages
best = {}
for release in data.values():
    channel = CHANNELS.get(release["channel"])
    if not channel:
        continue
    files = wanted_files(release, channel)
    if not files:
        continue  # no Windows assets (e.g. newest nightly still uploading)
    if channel not in best or release["published"] > best[channel][0]["published"]:
        best[channel] = (release, files)

if "stable" not in best:
    raise SystemExit("failed to find Brave stable release, aborting")

channels = {}
for channel, (release, files) in best.items():
    channels[channel] = {
        "version": release["name"],
        "published": release["published"],
        "chrome": release["dependencies"]["chrome"],
        "release": f"https://github.com/brave/brave-browser/releases/tag/{release['tag']}",
        "files": files,
    }

if "stable" not in channels:
    raise SystemExit("no Windows installers found for Brave stable, aborting")

out = {
    "name": "Brave",
    "version": channels["stable"]["version"],
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "source": URL,
    "channels": {c: channels[c] for c in ("stable", "beta", "nightly", "dev") if c in channels},
}

os.makedirs(os.path.join(os.environ["REPO_DIR"], "data"), exist_ok=True)
with open(os.path.join(os.environ["REPO_DIR"], "data", "brave.json"), "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"brave.json written: stable={out['version']}, channels={list(out['channels'])}")
EOF
