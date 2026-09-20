#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 )); then
  echo "Usage: $0 <commit-message> <path> [path ...]" >&2
  exit 2
fi

commit_message="$1"
shift

cd "$(git rev-parse --show-toplevel)"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add -- "$@"

if git diff --cached --quiet; then
  echo "Data unchanged, skipping commit"
  exit 0
fi

git commit -m "$commit_message"

for attempt in {1..5}; do
  git fetch origin main
  git rebase origin/main

  if git push origin HEAD:main; then
    exit 0
  fi

  if (( attempt == 5 )); then
    echo "Failed to push after ${attempt} attempts" >&2
    exit 1
  fi

  echo "Push raced with another workflow; retrying (${attempt}/5)"
  sleep $((attempt * 2))
done
