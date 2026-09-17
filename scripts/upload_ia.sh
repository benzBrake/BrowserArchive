#!/usr/bin/env bash
# Upload browser files to the Internet Archive item "<browser>-archive-<version>".
# Auth comes from the IA_ACCESS_KEY / IA_SECRET environment variables
# (generate keys at https://archive.org/account/s3.php).
# Usage: ./scripts/upload_ia.sh BROWSER VERSION WORK_DIR FILE [FILE...]
# Example: ./scripts/upload_ia.sh whale 4.32.1.150 build WhaleSetupX86.exe WhaleSetupX64.exe
set -euo pipefail

BROWSER="${1:?usage: upload_ia.sh BROWSER VERSION WORK_DIR FILE [FILE...]}"
VERSION="${2:?usage: upload_ia.sh BROWSER VERSION WORK_DIR FILE [FILE...]}"
WORK_DIR="${3:?usage: upload_ia.sh BROWSER VERSION WORK_DIR FILE [FILE...]}"
shift 3
[[ $# -gt 0 ]] || { echo "no files to upload" >&2; exit 1; }

ITEM_ID="${BROWSER}-archive-${VERSION}"
TITLE="${IA_TITLE:-${BROWSER} ${VERSION} installers (archived)}"
DESCRIPTION="${IA_DESCRIPTION:-${BROWSER} ${VERSION} official installers, archived from the official source for historical reference. All rights belong to the respective copyright holder.}"

if [[ -z "${IA_ACCESS_KEY:-}" || -z "${IA_SECRET:-}" ]]; then
  echo "IA_ACCESS_KEY and IA_SECRET must be set" >&2
  exit 1
fi

# internetarchive >= 5 reads IA_ACCESS_KEY_ID / IA_SECRET_ACCESS_KEY
export IA_ACCESS_KEY_ID="${IA_ACCESS_KEY}"
export IA_SECRET_ACCESS_KEY="${IA_SECRET}"

if ! command -v ia >/dev/null 2>&1; then
  pip install --quiet internetarchive
fi

FILES=()
for f in "$@"; do
  if [[ ! -f "${WORK_DIR}/${f}" ]]; then
    echo "Missing ${WORK_DIR}/${f}" >&2
    exit 1
  fi
  FILES+=("${WORK_DIR}/${f}")
done

ia upload "$ITEM_ID" "${FILES[@]}" \
  --metadata "collection:opensource_media" \
  --metadata "mediatype:software" \
  --metadata "title:${TITLE}" \
  --metadata "description:${DESCRIPTION}" \
  --metadata "date:$(date +%Y-%m-%d)" \
  --checksum

echo "ITEM_URL=https://archive.org/details/${ITEM_ID}"
for f in "$@"; do
  echo "FILE_URL_${f%%.*}=https://archive.org/download/${ITEM_ID}/${f}"
done
