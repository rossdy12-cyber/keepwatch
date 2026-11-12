#!/usr/bin/env bash
# Stark Mac Builder — runs on the home Mac (launchd, every 60s).
# Fetches the Stark build repo, works out which app folder(s) changed since the last build,
# and runs ONLY those apps' build-and-publish.sh (which build unsigned and POST the IPA to the
# TrueNAS signer). Same behaviour as the Codemagic dispatcher, minus the queue.
set -uo pipefail

BASE="$HOME/StarkBuilder"
REPO="$BASE/repo"
LOGS="$BASE/logs"
STATE="$BASE/last-built-sha"
LOCK="$BASE/.lock"
BRANCH="${STARK_BRANCH:-main}"

# launchd starts with a bare PATH; add Homebrew (Intel + Apple Silicon) for xcodegen.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Never block on a password prompt under launchd; credentials come from the macOS Keychain.
export GIT_TERMINAL_PROMPT=0
# The store upload token lives in the login Keychain (install.sh puts it there); build scripts read it from here.
SIDESTORE_UPLOAD_TOKEN="$(security find-generic-password -s stark-upload-token -w 2>/dev/null || true)"
export SIDESTORE_UPLOAD_TOKEN

mkdir -p "$LOGS"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGS/agent.log"; }

# One build at a time (mkdir is atomic; macOS has no flock). Clear a stale lock after 2h.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK" || exit 0
  else exit 0; fi
fi
trap 'rm -rf "$LOCK"' EXIT

cd "$REPO" || { log "repo missing at $REPO — run install.sh"; exit 1; }
[ -n "$SIDESTORE_UPLOAD_TOKEN" ] || { log "no upload token in Keychain (service stark-upload-token) — re-run install.sh"; exit 1; }
git fetch -q origin "$BRANCH" || { log "git fetch failed"; exit 1; }
NEW=$(git rev-parse "origin/$BRANCH")
LAST=$(cat "$STATE" 2>/dev/null || true)
[ "$NEW" = "$LAST" ] && exit 0

if [ -z "$LAST" ] || ! git cat-file -e "${LAST}^{commit}" 2>/dev/null; then
  # No usable baseline: don't rebuild everything — just record where we are.
  echo "$NEW" > "$STATE"; log "baseline set to ${NEW:0:8}"; exit 0
fi

CHANGED=$(git diff --name-only "$LAST" "$NEW")
git reset -q --hard "$NEW"
git clean -qfdx -e '*/build/' -e '*/out/' >/dev/null 2>&1 || true

APPS=$(echo "$CHANGED" | awk -F/ 'NF>1 {print $1}' | sort -u)
log "new commit ${NEW:0:8} (was ${LAST:0:8}); changed folders: ${APPS:-<none>}"

for app in $APPS; do
  if   [ -f "$app/build-and-publish.sh" ];    then SCRIPT="$app/build-and-publish.sh"
  elif [ -f "$app/ci/build-and-publish.sh" ]; then SCRIPT="$app/ci/build-and-publish.sh"
  else log "  $app: no build-and-publish.sh, skipping"; continue; fi
  L="$LOGS/${NEW:0:8}-$app.log"
  log "  building $app ($SCRIPT) -> $L"
  if bash "$SCRIPT" > "$L" 2>&1; then log "  $app OK"
  else log "  $app FAILED (see $L)"
       osascript -e "display notification \"$app build failed\" with title \"Stark Mac Builder\"" 2>/dev/null || true
  fi
done

# Record even on failure so a broken commit isn't retried every minute; push a fix to rebuild.
echo "$NEW" > "$STATE"
