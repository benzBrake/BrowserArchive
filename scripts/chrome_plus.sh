#!/usr/bin/env bash
# Scrape the latest stable Chrome Plus GitHub release and write data/chrome_plus.json.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -n "${PROXY:-}" ]]; then export https_proxy="$PROXY" http_proxy="$PROXY"; fi
PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --no-project python' || echo 'python3')"
$PY - <<'EOF'
import datetime, json, os, tempfile, urllib.request
API = "https://api.github.com/repos/Bush2021/chrome_plus/releases/latest"
request = urllib.request.Request(API, headers={"Accept": "application/vnd.github+json", "User-Agent": "BrowserArchive"})
with urllib.request.urlopen(request, timeout=60) as response: release = json.load(response)
if release.get("draft") or release.get("prerelease"): raise SystemExit("latest Chrome Plus release is not a stable release")
tag = (release.get("tag_name") or "").strip()
version = tag.lstrip("vV").strip()
if not version: raise SystemExit("Chrome Plus release has no version")
files, seen = [], set()
for asset in release.get("assets", []):
    name, url = (asset.get("name") or "").strip(), (asset.get("browser_download_url") or "").strip()
    if not name or not url or url in seen: continue
    seen.add(url); item = {"filename": name, "url": url}
    for key in ("size", "content_type", "download_count", "created_at", "updated_at"):
        if asset.get(key) is not None: item[key] = asset[key]
    files.append(item)
files.sort(key=lambda item: (item["filename"], item["url"]))
if not files: raise SystemExit(f"no assets found in Chrome Plus release {tag}")
release_data = {key: release.get(key) for key in ("tag_name", "name", "published_at", "created_at", "html_url", "body", "prerelease", "draft")}
out = {"name": "Chrome Plus", "version": version, "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"), "source": release.get("html_url") or f"https://github.com/Bush2021/chrome_plus/releases/tag/{tag}", "release": release_data, "files": files}
data_dir = os.path.join(os.environ["REPO_DIR"], "data"); os.makedirs(data_dir, exist_ok=True)
target = os.path.join(data_dir, "chrome_plus.json")
fd, temp_path = tempfile.mkstemp(prefix=".chrome_plus.", suffix=".json", dir=data_dir, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output: json.dump(out, output, indent=2, ensure_ascii=False); output.write("\n")
    os.replace(temp_path, target)
finally:
    if os.path.exists(temp_path): os.unlink(temp_path)
print(f"chrome_plus.json written: version={version}, files={len(files)}")
EOF
