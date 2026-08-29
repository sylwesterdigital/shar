#!/bin/zsh
set -e
set -o pipefail
export GIT_PAGER=cat PAGER=cat GH_PAGER=cat GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
EXPECTED_REMOTE="${EXPECTED_REMOTE:-git@github.com:sylwesterdigital/shar.git}"
GH_REPO="${GH_REPO:-sylwesterdigital/shar}"
BRANCH="${RELEASE_BRANCH:-main}"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
log(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "Shar releases must run on macOS."
for t in git gh rsync ssh curl shasum xcodebuild xcrun security python3 node; do command -v "$t" >/dev/null 2>&1 || fail "Required release tool missing: $t"; done
[[ -d .git ]] || fail "$ROOT is not a Git checkout."
[[ "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)" == "$BRANCH" ]] || fail "Release must run on branch $BRANCH."
[[ -z "$(git diff --name-only --diff-filter=U)" ]] || fail "Resolve Git conflicts before release."
CURRENT_REMOTE="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$CURRENT_REMOTE" ]]; then git remote add origin "$EXPECTED_REMOTE"; elif [[ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]]; then git remote set-url origin "$EXPECTED_REMOTE"; fi
git ls-remote origin HEAD >/dev/null 2>&1 || fail "Git SSH access to $EXPECTED_REMOTE failed."
gh auth status -h github.com >/dev/null 2>&1 || fail "GitHub CLI is not authenticated."

log "Repository verification"
./scripts/verify_repo.sh
log "Remote signaling protocol smoke test"
./scripts/test_remote_protocol.sh
log "Release/deployment credentials"
./scripts/check_macos_release_credentials.sh
./scripts/setup_android_release.sh
./scripts/check_android_release_credentials.sh
./scripts/check_ios_release_credentials.sh
./scripts/check_remote_share.sh
source ./scripts/release_profile.sh
shar_load_release_profile
ssh -o BatchMode=yes -o ConnectTimeout=12 -p "$SHAR_REMOTE_PORT" "$SHAR_REMOTE_USER@$SHAR_REMOTE_HOST" true || fail "Homepage SSH access failed."

log "Building all clients"
./scripts/build_all.sh

log "Deploying/validating remote WebRTC signaling + TURN"
./scripts/deploy_remote_share.sh

log "Committing release source"
git add -A
if git diff --cached --quiet; then
  log "No source changes to commit; using existing HEAD."
else
  git commit -m "Release v$VERSION"
fi
log "Pushing $BRANCH"
git push origin "$BRANCH"

log "Publishing GitHub Release $TAG"
./scripts/publish_github_release.sh

log "Deploying https://mojoworks.xyz/labs/shar/"
./scripts/deploy_homepage.sh

printf '\n============================================================\n'
printf 'SHAR RELEASE v%s COMPLETED SUCCESSFULLY\n' "$VERSION"
printf 'GitHub: https://github.com/%s/releases/tag/%s\n' "$GH_REPO" "$TAG"
printf 'Homepage: https://mojoworks.xyz/labs/shar/\n'
printf '============================================================\n'
