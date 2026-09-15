#!/usr/bin/env bash
# Scrape the latest stable Helium Windows release from GitHub and write
# data/helium.json. Links only; assets are not downloaded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${PROXY:-}" ]]; then
  export https_proxy="$PROXY" http_proxy="$PROXY"
fi

PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --no-project python' || echo 'python3')"

$PY - <<'EOF'
import datetime, json, os, urllib.request

API = "https://api.github.com/repos/imputnet/helium-windows/releases/latest"
request = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json", "User-Agent": "BrowserArchive"})
with urllib.request.urlopen(request, timeout=60) as response:
    release = json.load(response)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest Helium release is not a stable release")
version = (release.get("tag_name") or release.get("name") or "").strip()
if version.startswith("v"):
    version = version[1:]
if not version:
    raise SystemExit("Helium release has no version")

files = []
for asset in release.get("assets", []):
    name = asset.get("name", "")
    lower = name.lower()
    if lower.endswith((".sha256", ".sha512", ".md5", ".asc", ".sig")):
        continue
    if "source code" in lower or lower.startswith(("sha256", "sha512", "checksums")):
        continue
    if not lower.endswith((".exe", ".msi", ".zip")):
        continue
    url = asset.get("browser_download_url")
    if url:
        files.append({"filename": name, "url": url})
if not files:
    raise SystemExit("no Windows installer assets found in Helium release")

out = {
    "name": "Helium",
    "version": version,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "source": release.get("html_url") or "https://github.com/imputnet/helium-windows/releases/latest",
    "files": files,
}
path = os.path.join(os.environ["REPO_DIR"], "data", "helium.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"helium.json written: version={version}, files={len(files)}")
EOF
