#!/usr/bin/env bash
set -euo pipefail

generator=""
if [[ "${1:-}" == "--generate" ]]; then
  if (( $# < 4 )); then
    echo "Usage: $0 --generate <script> <commit-message> <path> [path ...]" >&2
    exit 2
  fi
  generator="$2"
  shift 2
fi

if (( $# < 2 )); then
  echo "Usage: $0 <commit-message> <path> [path ...]" >&2
  exit 2
fi

commit_message="$1"
shift

cd "$(git rev-parse --show-toplevel)"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Regeneration mode is for clean, disposable workflow checkouts. Rebuild from
# the current remote tip on every attempt instead of merging generated JSON.
if [[ -n "$generator" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Regeneration requires a clean worktree and index" >&2
    exit 1
  fi
  git fetch origin main
  git merge --ff-only origin/main
  for attempt in {1..5}; do
    bash "$generator"
    git add -- "$@"
    if git diff --cached --quiet; then
      echo "Data unchanged, skipping commit"
      exit 0
    fi
    git commit -m "$commit_message"
    if git push origin HEAD:main; then
      exit 0
    fi
    if (( attempt == 5 )); then
      echo "Failed to push after ${attempt} attempts" >&2
      exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
      echo "Unexpected worktree changes; refusing to discard them" >&2
      exit 1
    fi
    echo "Push failed; syncing and regenerating (${attempt}/5)"
    sleep $((attempt * 2))
    git fetch origin main
    git reset --hard origin/main
  done
  exit 1
fi

git add -- "$@"

if git diff --cached --quiet; then
  echo "Data unchanged, skipping commit"
  exit 0
fi

git commit -m "$commit_message"

for attempt in {1..5}; do
  git fetch origin main
  if ! git rebase --autostash origin/main; then
    echo "Rebase failed; worktree status:" >&2
    git status --short >&2
    exit 1
  fi

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
