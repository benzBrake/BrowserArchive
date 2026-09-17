#!/usr/bin/env bash
# Generate a Firefox update manifest for the latest stable uBlock Origin release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export UBLOCK_OUTPUT_PATH="${UBLOCK_OUTPUT_PATH:-$REPO_DIR/data/ublock-origin.json}"

if [[ -n "${PROXY:-}" ]]; then
  export https_proxy="$PROXY" http_proxy="$PROXY"
fi

if command -v uv >/dev/null 2>&1; then
  PY=(uv run --no-project python)
elif command -v python3 >/dev/null 2>&1; then
  PY=(python3)
else
  PY=(python)
fi

"${PY[@]}" - <<'PY'
import hashlib
import json
import os
import re
import tempfile
import urllib.request
import zipfile


API = "https://api.github.com/repos/gorhill/uBlock/releases/latest"
ADDON_ID = "uBlock0@raymondhill.net"
ASSET_PREFIX = "https://github.com/gorhill/uBlock/releases/download/"
PROXY_PREFIX = "https://v6.gh-proxy.org/"


def request(url, *, github_api=False):
    headers = {"User-Agent": "BrowserArchive"}
    if github_api:
        headers["Accept"] = "application/vnd.github+json"
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


with urllib.request.urlopen(request(API, github_api=True), timeout=60) as response:
    release = json.load(response)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest uBlock Origin release is not stable")

tag = (release.get("tag_name") or "").strip()
version = tag[1:] if tag.startswith("v") else tag
if not version or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
    raise SystemExit(f"invalid uBlock Origin release tag: {tag!r}")

asset_name = f"uBlock0_{version}.firefox.signed.xpi"
assets = [asset for asset in release.get("assets", []) if asset.get("name") == asset_name]
if len(assets) != 1:
    raise SystemExit(
        f"expected exactly one {asset_name!r} asset in release {tag!r}, found {len(assets)}"
    )

asset = assets[0]
if asset.get("state") not in (None, "uploaded"):
    raise SystemExit(f"uBlock Origin asset is not ready: state={asset.get('state')!r}")
download_url = asset.get("browser_download_url") or ""
if not download_url.startswith(ASSET_PREFIX):
    raise SystemExit(f"unexpected uBlock Origin asset URL: {download_url!r}")

digest = hashlib.sha512()
xpi_fd, xpi_path = tempfile.mkstemp(suffix=".xpi")
os.close(xpi_fd)
try:
    with urllib.request.urlopen(request(download_url), timeout=120) as response:
        with open(xpi_path, "wb") as xpi_file:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                xpi_file.write(chunk)

    try:
        with zipfile.ZipFile(xpi_path) as archive:
            manifest = json.loads(archive.read("manifest.json").decode("utf-8"))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
        raise SystemExit(f"invalid uBlock Origin XPI: {exc}") from exc
finally:
    os.unlink(xpi_path)

if not isinstance(manifest, dict):
    raise SystemExit("XPI manifest root is not an object")

manifest_version = str(manifest.get("version") or "")
browser_settings = manifest.get("browser_specific_settings")
if not isinstance(browser_settings, dict):
    raise SystemExit("XPI manifest has no browser_specific_settings object")
gecko = browser_settings.get("gecko")
if not isinstance(gecko, dict):
    raise SystemExit("XPI manifest has no Gecko settings object")
manifest_id = gecko.get("id")
strict_min_version = gecko.get("strict_min_version")
if manifest_version != version:
    raise SystemExit(
        f"XPI version {manifest_version!r} does not match release version {version!r}"
    )
if manifest_id != ADDON_ID:
    raise SystemExit(f"unexpected XPI add-on ID: {manifest_id!r}")
if not isinstance(strict_min_version, str) or not strict_min_version:
    raise SystemExit("XPI manifest has no Gecko strict_min_version")

output = {
    "addons": {
        ADDON_ID: {
            "updates": [
                {
                    "update_hash": f"sha512:{digest.hexdigest().upper()}",
                    "version": version,
                    "update_link": f"{PROXY_PREFIX}{download_url}",
                    "applications": {
                        "gecko": {"strict_min_version": strict_min_version}
                    },
                }
            ]
        }
    }
}

output_path = os.environ["UBLOCK_OUTPUT_PATH"]
output_dir = os.path.dirname(os.path.abspath(output_path))
os.makedirs(output_dir, exist_ok=True)
temporary_path = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        dir=output_dir,
        prefix=".ublock-origin.",
        suffix=".tmp",
        delete=False,
    ) as output_file:
        temporary_path = output_file.name
        json.dump(output, output_file, indent=2, ensure_ascii=False)
        output_file.write("\n")
        output_file.flush()
        os.fsync(output_file.fileno())
    os.replace(temporary_path, output_path)
    temporary_path = None
finally:
    if temporary_path and os.path.exists(temporary_path):
        os.unlink(temporary_path)

print(f"ublock-origin.json written: version={version}")
PY
