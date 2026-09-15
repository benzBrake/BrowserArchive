#!/usr/bin/env bash
# Scrape the latest stable Waterfox release from GitHub and write
# data/waterfox.json. Links are taken from release assets when available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${PROXY:-}" ]]; then
  export https_proxy="$PROXY" http_proxy="$PROXY"
fi

PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --no-project python' || echo 'python3')"

$PY - <<'EOF'
import datetime, json, os, re, urllib.request, urllib.parse

API = "https://api.github.com/repos/BrowserWorks/waterfox/releases/latest"
request = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json", "User-Agent": "BrowserArchive"})
with urllib.request.urlopen(request, timeout=60) as response:
    release = json.load(response)
if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest Waterfox release is not a stable release")
version = (release.get("tag_name") or release.get("name") or "").strip().lstrip("v")
if not version:
    raise SystemExit("Waterfox release has no version")
files = []
for asset in release.get("assets", []):
    name = asset.get("name", "")
    if name.lower().endswith((".exe", ".msi", ".zip", ".dmg", ".pkg", ".tar.bz2")):
        if asset.get("browser_download_url"):
            files.append({"filename": name, "url": asset["browser_download_url"]})
# Waterfox publishes binary downloads on its CDN rather than as GitHub assets.
page_req = urllib.request.Request("https://www.waterfox.com/download/", headers={"User-Agent": "BrowserArchive"})
with urllib.request.urlopen(page_req, timeout=60) as response:
    page = response.read().decode("utf-8", "replace")
for url in dict.fromkeys(re.findall(r'https://cdn\.waterfox\.com/[^" ]+', page)):
    url = url.replace("&amp;", "&")
    if f"/releases/{version}/" not in url:
        continue
    name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
    if name.lower().endswith((".exe", ".msi", ".zip", ".dmg", ".pkg", ".tar.bz2")):
        files.append({"filename": name, "url": url})
files = list({item["url"]: item for item in files}.values())
out = {
    "name": "Waterfox",
    "version": version,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "source": release.get("html_url") or "https://github.com/BrowserWorks/waterfox/releases/latest",
    "files": files,
}
path = os.path.join(os.environ["REPO_DIR"], "data", "waterfox.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"waterfox.json written: version={version}, files={len(files)}")
EOF
