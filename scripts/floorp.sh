#!/usr/bin/env bash
# Scrape the latest stable Floorp Windows release and matching portable build
# from GitHub, then write data/floorp.json. Links only; assets are not downloaded.
# Env: PROXY (optional, for local debugging)
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
import urllib.parse
import urllib.request

MAIN_API = "https://api.github.com/repos/Floorp-Projects/Floorp/releases/latest"
PORTABLE_API = "https://api.github.com/repos/Floorp-Projects/Floorp-Portable-v2/releases/tags/"
USER_AGENT = "BrowserArchive"


def fetch_json(url):
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
        },
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def normalize_version(value):
    return re.sub(r"^[vV]", "", (value or "").strip())


def is_ignored_asset(name):
    lower = name.lower()
    return (
        "source code" in lower
        or lower.startswith(("sha256", "sha512", "checksums", "checksum"))
        or lower.endswith((".sha256", ".sha512", ".md5", ".asc", ".sig", ".json"))
    )


def main_windows_asset(name):
    lower = name.lower()
    if is_ignored_asset(name) or not lower.endswith((".exe", ".msi", ".zip")):
        return False
    # Executable installers are Windows-specific by definition. Restrict ZIP
    # files to Windows-looking names so source archives cannot be included.
    return lower.endswith((".exe", ".msi")) or any(
        token in lower for token in ("win", "windows")
    )


def portable_windows_asset(name):
    lower = name.lower()
    if is_ignored_asset(name) or not lower.endswith((".7z", ".zip")):
        return False
    return "portable" in lower and any(token in lower for token in ("win", "windows"))


def release_files(release, predicate):
    files = []
    for asset in release.get("assets", []):
        name = (asset.get("name") or "").strip()
        url = (asset.get("browser_download_url") or "").strip()
        if not name or not url or not predicate(name):
            continue
        files.append({"filename": name, "url": url})
    # Stable ordering and URL de-duplication avoid noisy commits when GitHub
    # changes asset ordering or exposes the same file more than once.
    return sorted(
        {item["url"]: item for item in files}.values(),
        key=lambda item: (item["filename"], item["url"]),
    )


main_release = fetch_json(MAIN_API)
if main_release.get("draft") or main_release.get("prerelease"):
    raise SystemExit("latest Floorp release is not a stable release")

tag = (main_release.get("tag_name") or "").strip()
if not tag:
    raise SystemExit("Floorp release has no tag")
version = normalize_version(tag)
if not version:
    raise SystemExit("Floorp release has no version")

main_files = release_files(main_release, main_windows_asset)
if not main_files:
    raise SystemExit(f"no Windows installer assets found in Floorp release {tag}")

# The portable repository is queried by the exact main-release tag. A missing
# release, draft/prerelease, or normalized version mismatch is fatal so the
# archive never combines binaries from different Floorp versions.
portable_url = PORTABLE_API + urllib.parse.quote(tag, safe="")
try:
    portable_release = fetch_json(portable_url)
except Exception as exc:
    raise SystemExit(f"matching Floorp portable release {tag!r} unavailable: {exc}") from exc
if portable_release.get("draft") or portable_release.get("prerelease"):
    raise SystemExit(f"matching Floorp portable release {tag!r} is not stable")
portable_tag = (portable_release.get("tag_name") or "").strip()
if normalize_version(portable_tag) != version:
    raise SystemExit(
        f"Floorp portable version mismatch: expected {version}, "
        f"got {normalize_version(portable_tag) or '<missing>'}"
    )
portable_files = release_files(portable_release, portable_windows_asset)
if not portable_files:
    raise SystemExit(f"no Windows portable assets found in Floorp portable release {tag}")

files = sorted(
    main_files + portable_files,
    key=lambda item: (item["filename"], item["url"]),
)
out = {
    "name": "Floorp",
    "version": version,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
    "source": main_release.get("html_url")
    or f"https://github.com/Floorp-Projects/Floorp/releases/tag/{tag}",
    "files": files,
}

data_dir = os.path.join(os.environ["REPO_DIR"], "data")
os.makedirs(data_dir, exist_ok=True)
target = os.path.join(data_dir, "floorp.json")
fd, temp_path = tempfile.mkstemp(
    prefix=".floorp.", suffix=".json", dir=data_dir, text=True
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(out, output, indent=2, ensure_ascii=False)
        output.write("\n")
    os.replace(temp_path, target)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)

print(f"floorp.json written: version={version}, files={len(files)}")
EOF
