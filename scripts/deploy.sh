#!/bin/zsh

# Build, sign, install, launch, commit and push the current LocalWebShare release.
# Intended to be called by build-watch.sh, but can also be run directly.

set -e
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
EXPECTED_REMOTE="${EXPECTED_REMOTE:-git@github.com:sylwesterdigital/shar.git}"

cd "$REPO_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d .git ]] || fail "$REPO_DIR is not a Git checkout."
[[ -f VERSION ]] || fail "VERSION is missing."
[[ -f README.md ]] || fail "README.md is missing."
[[ -f CHANGELOG.md ]] || fail "CHANGELOG.md is missing."
[[ -f .gitignore ]] || fail ".gitignore is missing."
[[ -x scripts/app_build.sh ]] || fail "scripts/app_build.sh is missing or not executable."

VERSION_VALUE="$(tr -d '[:space:]' < VERSION)"
[[ -n "$VERSION_VALUE" ]] || fail "VERSION is empty."

grep -q "${VERSION_VALUE}" README.md || fail "README.md does not mention v$VERSION_VALUE."
grep -q "\[${VERSION_VALUE}\]" CHANGELOG.md || fail "CHANGELOG.md has no entry for v$VERSION_VALUE."
grep -q '^/archive/$' .gitignore || fail "archive/ is not ignored by Git."

CURRENT_REMOTE="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$CURRENT_REMOTE" ]]; then
    log "Adding Git origin: $EXPECTED_REMOTE"
    git remote add origin "$EXPECTED_REMOTE"
elif [[ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]]; then
    log "Updating Git origin: $CURRENT_REMOTE -> $EXPECTED_REMOTE"
    git remote set-url origin "$EXPECTED_REMOTE"
fi

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" ]] || fail "Repository is in detached HEAD state."

log "Release v$VERSION_VALUE"
log "Branch: $BRANCH"
log "Remote: $EXPECTED_REMOTE"

echo
echo ">>> ./scripts/app_build.sh"
./scripts/app_build.sh

echo
log "App build/install/launch succeeded."
log "Preparing Git release commit..."

git add -A

if git diff --cached --quiet; then
    log "No source changes to commit."
else
    git commit -m "Release v$VERSION_VALUE"
fi

echo
log "Pushing $BRANCH to origin..."
git push origin "$BRANCH"

echo
log "Deployment complete: v$VERSION_VALUE"
