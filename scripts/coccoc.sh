#!/usr/bin/env bash
# Resolve and package the latest official Coc Coc Windows x64 application.
# Usage:
#   ./scripts/coccoc.sh metadata
#   ./scripts/coccoc.sh build VERSION DOWNLOAD_URL DOWNLOAD_SHA256
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_DIR/build/coccoc}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_DIR/build}"
UPDATE_URL="https://update.coccoc.com/service/update2/json"

CURL_OPTS=(--fail --retry 3 --location --silent --show-error)
if curl --version | grep -q schannel; then
  CURL_OPTS+=(--ssl-no-revoke)
fi
if [[ -n "${PROXY:-}" ]]; then
  CURL_OPTS+=(--proxy "$PROXY")
fi

if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON=(python)
else
  echo "python3 or python is required" >&2
  exit 1
fi

resolve_metadata() {
  local response
  response="$(curl "${CURL_OPTS[@]}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "User-Agent: CocCocUpdater/0.0.0.0" \
    --data-binary @- "$UPDATE_URL" <<'EOF'
{"request":{"@os":"win","@updater":"CocCocUpdater","acceptformat":"crx3,download,puff,run,xz,zucc","apps":[{"ap":"arch_x64","appid":"{c0cc0cbb-47dd-46ff-a04d-7011a06486e1}","brand":"XXXX","enabled":true,"installsource":"taggedmi","updatecheck":{"sameversionupdate":true},"version":"0.0.0.0"}],"arch":"x86","ismachine":true,"os":{"arch":"x86_64","platform":"Windows","version":"10.0"},"prodversion":"0.0.0.0","protocol":"4.0","updaterversion":"0.0.0.0","wow64":true}}
EOF
  )"

  COCCOC_RESPONSE="$response" "${PYTHON[@]}" - <<'PY'
import json
import os
import re

raw = os.environ["COCCOC_RESPONSE"].strip()
if raw.startswith(")]}'"):
    raw = raw[4:].lstrip()
data = json.loads(raw)
apps = data.get("response", {}).get("apps") or []
if not apps:
    raise SystemExit("Coc Coc update response contains no applications")
update = apps[0].get("updatecheck") or {}
if update.get("status") != "ok":
    status = update.get("status", "missing status")
    raise SystemExit(f"Coc Coc update check failed: {status}")
version = str(update.get("nextversion") or "").strip()
if not re.fullmatch(r"\d+(?:\.\d+){3}", version):
    raise SystemExit(f"invalid Coc Coc version: {version!r}")

download_url = ""
download_sha256 = ""
for pipeline in update.get("pipelines") or []:
    for operation in pipeline.get("operations") or []:
        if operation.get("type") != "download":
            continue
        urls = operation.get("urls") or []
        if urls:
            download_url = str(urls[0].get("url") or "").strip()
            download_sha256 = str((operation.get("out") or {}).get("sha256") or "").strip().lower()
            break
    if download_url:
        break
if not download_url.startswith("https://"):
    raise SystemExit("Coc Coc update response has no HTTPS download URL")
if not re.fullmatch(r"[0-9a-f]{64}", download_sha256):
    raise SystemExit("Coc Coc update response has no valid SHA-256")

print(f"VERSION={version}")
print(f"DOWNLOAD_URL={download_url}")
print(f"DOWNLOAD_SHA256={download_sha256}")
PY
}

find_seven_zip() {
  if [[ -n "${SEVEN_ZIP:-}" ]]; then
    printf '%s\n' "$SEVEN_ZIP"
  elif command -v 7z >/dev/null 2>&1; then
    command -v 7z
  elif command -v 7zz >/dev/null 2>&1; then
    command -v 7zz
  elif [[ -x "/c/Program Files/7-Zip/7z.exe" ]]; then
    printf '%s\n' "/c/Program Files/7-Zip/7z.exe"
  else
    echo "7z or 7zz is required" >&2
    return 1
  fi
}

extract_application() {
  local seven_zip="$1" payload="$2" root="$3"
  local next archive browser

  "$seven_zip" x -y "-o$root" "$payload" >/dev/null
  for level in 1 2 3 4 5; do
    browser="$(find "$root" -type f -iname browser.exe -print -quit)"
    if [[ -n "$browser" ]]; then
      dirname "$browser"
      return 0
    fi

    archive="$(find "$root" -type f -iname browser.7z -print -quit)"
    if [[ -z "$archive" ]]; then
      archive="$(find "$root" -type f -iname '*coccocsetup.exe' -print -quit)"
    fi
    if [[ -z "$archive" ]]; then
      archive="$(find "$root" -maxdepth 2 -type f -iname '*.7z' -print -quit)"
    fi
    if [[ -z "$archive" ]]; then
      echo "browser.exe or a nested Coc Coc payload was not found" >&2
      return 1
    fi

    next="$WORK_DIR/extract-$level"
    mkdir -p "$next"
    "$seven_zip" x -y "-o$next" "$archive" >/dev/null
    root="$next"
  done

  echo "browser.exe was not found after five extraction levels" >&2
  return 1
}

build_archive() {
  if [[ $# -ne 3 ]]; then
    echo "usage: $0 build VERSION DOWNLOAD_URL DOWNLOAD_SHA256" >&2
    return 2
  fi

  local version="$1" download_url="$2" expected_sha256="${3,,}"
  local seven_zip payload actual_sha256 extract_root app_dir browser_version
  local stage archive_name archive_path archive_sha256

  [[ "$version" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { echo "invalid version: $version" >&2; return 1; }
  [[ "$download_url" == https://* ]] || { echo "download URL must use HTTPS" >&2; return 1; }
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid download SHA-256" >&2; return 1; }
  case "$WORK_DIR" in
    "$REPO_DIR"/build/*) ;;
    *) echo "WORK_DIR must be inside $REPO_DIR/build" >&2; return 1 ;;
  esac

  seven_zip="$(find_seven_zip)"
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
  payload="$WORK_DIR/coccoc-update.crx"

  actual_sha256=""
  if [[ -f "$payload" ]]; then
    actual_sha256="$(sha256sum "$payload" | awk '{print $1}')"
  fi
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "Downloading Coc Coc $version ..." >&2
    rm -f "$payload"
    curl "${CURL_OPTS[@]}" -o "$payload" "$download_url"
    actual_sha256="$(sha256sum "$payload" | awk '{print $1}')"
  else
    echo "Reusing the verified Coc Coc $version download." >&2
  fi
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    echo "download SHA-256 mismatch: expected $expected_sha256, got $actual_sha256" >&2
    return 1
  fi

  rm -rf "$WORK_DIR"/extract-* "$WORK_DIR/stage"
  extract_root="$WORK_DIR/extract-0"
  mkdir -p "$extract_root"
  app_dir="$(extract_application "$seven_zip" "$payload" "$extract_root")"

  if command -v uv >/dev/null 2>&1; then
    browser_version="$(uv run --with pefile --no-project python "$SCRIPT_DIR/get_version.py" "$app_dir/browser.exe")"
  else
    browser_version="$("${PYTHON[@]}" "$SCRIPT_DIR/get_version.py" "$app_dir/browser.exe")"
  fi
  if [[ "$browser_version" != "$version" ]]; then
    echo "browser.exe version mismatch: expected $version, got $browser_version" >&2
    return 1
  fi

  stage="$WORK_DIR/stage"
  mkdir -p "$stage/CocCoc"
  cp -a "$app_dir/." "$stage/CocCoc/"
  while IFS= read -r -d '' installer_dir; do
    rm -rf "$installer_dir"
  done < <(find "$stage/CocCoc" -type d -iname Installer -print0)

  archive_name="coccoc-${version}-win-x64.zip"
  archive_path="$OUTPUT_DIR/$archive_name"
  rm -f "$archive_path"
  (cd "$stage" && "$seven_zip" a -tzip -mx=9 "$archive_path" CocCoc >/dev/null)
  archive_sha256="$(sha256sum "$archive_path" | awk '{print $1}')"

  printf 'ARCHIVE_NAME=%s\n' "$archive_name"
  printf 'ARCHIVE_SHA256=%s\n' "$archive_sha256"
}

case "${1:-}" in
  metadata)
    [[ $# -eq 1 ]] || { echo "usage: $0 metadata" >&2; exit 2; }
    resolve_metadata
    ;;
  build)
    shift
    build_archive "$@"
    ;;
  *)
    echo "usage: $0 {metadata|build VERSION DOWNLOAD_URL DOWNLOAD_SHA256}" >&2
    exit 2
    ;;
esac
