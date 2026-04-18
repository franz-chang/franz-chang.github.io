#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed or not in PATH."
  exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: current directory is not a git repository."
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
  echo "Error: detached HEAD state. Please checkout a branch first."
  exit 1
fi

if [[ $# -gt 0 ]]; then
  COMMIT_MSG="$*"
else
  COMMIT_MSG="chore: update homepage $(date '+%Y-%m-%d %H:%M:%S')"
fi

echo "Repository: $SCRIPT_DIR"
echo "Branch: $BRANCH"
echo "Commit message: $COMMIT_MSG"
echo

git add -A

# Skip common local noise files.
git reset -- .DS_Store .jekyll-local.log >/dev/null 2>&1 || true

if git diff --cached --quiet; then
  echo "No staged changes to commit."
  exit 0
fi

echo "Staged changes:"
git diff --cached --name-status
echo

git commit -m "$COMMIT_MSG"

if git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
  git push
else
  git push -u origin "$BRANCH"
fi

echo
echo "Done: changes committed and pushed."
