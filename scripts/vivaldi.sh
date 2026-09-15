#!/usr/bin/env bash
# Scrape the latest Vivaldi Windows installer links per channel from the
# update.vivaldi.com appcasts and write data/vivaldi.json
# (links only, no downloads; Vivaldi serves versioned permanent URLs).
# Channels: public/appcast.*.xml = stable, win/appcast.*.xml = snapshot.
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
import xml.etree.ElementTree as ET

BASE = "https://update.vivaldi.com/update/1.0"
# appcast directory per channel: public = stable feed, win = snapshot feed
CHANNELS = {"stable": f"{BASE}/public/appcast", "snapshot": f"{BASE}/win/appcast"}
ARCHES = ("x64", "arm64")  # x86 installers are no longer published
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def fetch_channel(base):
    # each appcast has a single <item>; its direct <enclosure> child is the
    # full installer (the ones inside <sparkle:deltas> are update patches)
    info = {}
    for arch in ARCHES:
        try:
            with urllib.request.urlopen(f"{base}.{arch}.xml", timeout=60) as resp:
                root = ET.fromstring(resp.read())
        except Exception as e:
            print(f"warn: {base}.{arch}.xml unavailable: {e}")
            continue
        item = root.find("channel/item")
        enclosure = None
        if item is not None:
            for el in item.findall("enclosure"):
                if ".delta." not in (el.get("url") or ""):
                    enclosure = el
                    break
        if enclosure is None or not enclosure.get("url"):
            print(f"warn: no full-installer enclosure in {base}.{arch}.xml")
            continue
        info[arch] = {
            "url": enclosure.get("url"),
            "version": enclosure.get(f"{{{SPARKLE}}}version"),
        }
        notes = item.find(f"{{{SPARKLE}}}releaseNotesLink")
        if notes is not None and notes.text:
            info.setdefault("release_notes", notes.text.strip())
    return info


channels = {}
for channel, base in CHANNELS.items():
    info = fetch_channel(base)
    version = info.get("x64", {}).get("version")
    if not version:
        if channel == "stable":
            raise SystemExit("no installer found for Vivaldi stable, aborting")
        print(f"warn: no installer found for {channel}, skipping channel")
        continue
    # arm64 appcast can lag x64 during a release; only record it when it matches
    if "arm64" in info and info["arm64"]["version"] != version:
        print(f"warn: {channel} arm64 version {info['arm64']['version']} != x64 {version}, dropping arm64")
        del info["arm64"]
    entry = {"version": version}
    if "release_notes" in info:
        entry["release_notes"] = info["release_notes"]
    entry["files"] = {
        arch: {"filename": info[arch]["url"].rsplit("/", 1)[1], "url": info[arch]["url"]}
        for arch in ARCHES if arch in info
    }
    channels[channel] = entry

out = {
    "name": "Vivaldi",
    "version": channels["stable"]["version"],
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "source": f"{CHANNELS['stable']}.x64.xml",
    "channels": {c: channels[c] for c in ("stable", "snapshot") if c in channels},
}

os.makedirs(os.path.join(os.environ["REPO_DIR"], "data"), exist_ok=True)
path = os.path.join(os.environ["REPO_DIR"], "data", "vivaldi.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"vivaldi.json written: stable={out['version']}, channels={list(out['channels'])}")
EOF
