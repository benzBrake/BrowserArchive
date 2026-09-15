#!/usr/bin/env bash
# Download Whale installers, extract whale.exe, print its version.
# Used by both GitHub Actions and local-debug.sh.
# Env: PROXY (optional), WORK_DIR (optional, default ./build)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$(pwd)/build}"
BASE_URL="https://installer-whale.pstatic.net/downloads/sa_installers"

CURL_OPTS=(--fail --retry 3 --location --silent --show-error)
if curl --version | grep -q schannel; then
  CURL_OPTS+=(--ssl-no-revoke) # local proxy blocks revocation checks on Windows curl
fi
if [[ -n "${PROXY:-}" ]]; then
  CURL_OPTS+=("--proxy" "$PROXY")
fi

PY="$(command -v uv >/dev/null 2>&1 && echo 'uv run --with pefile --no-project' || echo 'python3')"
SEVEN_ZIP="$(command -v 7z >/dev/null 2>&1 && echo 7z || echo '/c/Program Files/7-Zip/7z.exe')"

download() {
  local arch="$1"
  echo "Downloading WhaleSetup${arch}.exe ..."
  curl "${CURL_OPTS[@]}" -o "${WORK_DIR}/WhaleSetup${arch}.exe" \
    "${BASE_URL}/WhaleSetup${arch}.exe"
}

# The installer may nest whale.exe inside embedded 7z/installer archives;
# keep unpacking until we find it (max 5 levels).
extract_whale_exe() {
  local src="$1" out="$2"
  rm -rf "$out"
  mkdir -p "$out"
  cp "$src" "$out/setup.exe"
  for _ in 1 2 3 4 5; do
    local found
    found="$(find "$out" -iname whale.exe -print -quit || true)"
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
    # extract every archive-like file once per level
    local extracted_any=false
    while IFS= read -r f; do
      case "$f" in
        *.extracted) continue ;;
      esac
      d="${f}.extracted"
      mkdir -p "$d"
      if "$SEVEN_ZIP" x -y -o"$d" "$f" >/dev/null 2>&1; then
        rm -f "$f"
        extracted_any=true
      else
        rm -rf "$d"
      fi
    done < <(find "$out" -type f \( -iname '*.exe' -o -iname '*.7z' -o -iname '*.bin' \) | sort)
    if [[ "$extracted_any" == false ]]; then
      break
    fi
  done
  echo "whale.exe not found in $src" >&2
  return 1
}

mkdir -p "$WORK_DIR"
download X86
download X64
download ARM64

WHALE_EXE="$(extract_whale_exe "${WORK_DIR}/WhaleSetupX64.exe" "${WORK_DIR}/x64")"
VERSION="$($PY "${SCRIPT_DIR}/get_version.py" "$WHALE_EXE")"
echo "VERSION=${VERSION}"
