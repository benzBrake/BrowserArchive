#!/usr/bin/env bash
# Local debug entry: run the same download/extract/version flow as CI,
# with traffic routed through the local proxy.
# Usage: ./local-debug.sh [--release]
#   --release  also upload to the Internet Archive (requires IA_ACCESS_KEY / IA_SECRET)
set -euo pipefail

export PROXY="${PROXY:-http://127.0.0.1:10808}"
export http_proxy="$PROXY" https_proxy="$PROXY"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$ROOT/scripts/build.sh" "$ROOT/scripts/upload_ia.sh"

VERSION="$("$ROOT/scripts/build.sh" | grep '^VERSION=' | cut -d= -f2)"
echo "Detected Whale version: ${VERSION}"

if [[ "${1:-}" == "--release" ]]; then
  "$ROOT/scripts/upload_ia.sh" whale "$VERSION" "$ROOT/build" \
    WhaleSetupX86.exe WhaleSetupX64.exe WhaleSetupARM64.exe
  echo "Uploaded to Internet Archive"
else
  echo "Dry-run only. Use --release to upload to the Internet Archive."
fi
