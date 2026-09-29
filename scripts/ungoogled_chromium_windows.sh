#!/usr/bin/env bash
# Scrape the latest stable ungoogled-chromium Windows release from GitHub.
# The generated data file contains links and release metadata only; binaries
# are not downloaded by this workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -n "${PROXY:-}" ]]; then
  export https_proxy="$PROXY" http_proxy="$PROXY"
fi

PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --no-project python' || echo 'python3')"

$PY - <<'EOF'
import datetime
import json
import os
import re
import tempfile
import urllib.request

API = "https://api.github.com/repos/ungoogled-software/ungoogled-chromium-windows/releases/latest"
ASSET_RE = re.compile(
    r"^ungoogled-chromium_.+_(?:installer_(?:x86|x64|arm64)\.exe|windows_(?:x86|x64|arm64)\.zip)$",
    re.IGNORECASE,
)

request = urllib.request.Request(
    API,
    headers={"Accept": "application/vnd.github+json", "User-Agent": "BrowserArchive"},
)
with urllib.request.urlopen(request, timeout=60) as response:
    release = json.load(response)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest ungoogled-chromium Windows release is not stable")

tag = (release.get("tag_name") or "").strip()
tag_match = re.fullmatch(r"(\d+(?:\.\d+){3})(?:-(\d+(?:\.\d+)?))?", tag)
if not tag_match:
    raise SystemExit(f"invalid ungoogled-chromium Windows release tag: {tag!r}")
version, _package_revision = tag_match.groups()

files = []
for asset in release.get("assets", []):
    name = (asset.get("name") or "").strip()
    url = (asset.get("browser_download_url") or "").strip()
    if not name or not url or not ASSET_RE.fullmatch(name):
        continue
    item = {"filename": name, "url": url}
    for key in ("size", "content_type", "download_count", "created_at", "updated_at", "digest"):
        if asset.get(key) is not None:
            item[key] = asset[key]
    files.append(item)

files.sort(key=lambda item: item["filename"])
if not files:
    raise SystemExit(f"no Windows assets found in ungoogled-chromium release {tag}")

release_data = {
    key: release.get(key)
    for key in ("tag_name", "name", "published_at", "created_at", "html_url", "body", "prerelease", "draft")
}
out = {
    "name": "ungoogled-chromium Windows",
    # The executable reports the Chromium version without the downstream
    # package revision that is appended to the GitHub release tag.
    "version": version,
    "release_version": tag,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "source": release.get("html_url") or f"https://github.com/ungoogled-software/ungoogled-chromium-windows/releases/tag/{tag}",
    "release": release_data,
    "files": files,
}

data_dir = os.path.join(os.environ["REPO_DIR"], "data")
os.makedirs(data_dir, exist_ok=True)
target = os.path.join(data_dir, "ungoogled-chromium-windows.json")
fd, temp_path = tempfile.mkstemp(prefix=".ungoogled-chromium-windows.", suffix=".json", dir=data_dir, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(out, output, indent=2, ensure_ascii=False)
        output.write("\n")
    os.replace(temp_path, target)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)

print(f"ungoogled-chromium-windows.json written: version={version}, release={tag}, files={len(files)}")
EOF
