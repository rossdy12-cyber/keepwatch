#!/usr/bin/env bash
# One-time setup for the Stark Mac Builder.
#   bash install.sh <git-url-of-SonyAmpPreamp-repo> [branch]
set -euo pipefail

URL="${1:?usage: bash install.sh <git-url-of-build-repo> [branch]}"
BRANCH="${2:-main}"
BASE="$HOME/StarkBuilder"
LABEL="com.ross.starkbuilder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== Checking Xcode =="
xcodebuild -version || { echo "Xcode not ready. Open Xcode once, or run: sudo xcodebuild -license accept"; exit 1; }
xcrun --sdk iphoneos --show-sdk-version >/dev/null || { echo "No iOS SDK found — install iOS platform in Xcode > Settings > Components"; exit 1; }

echo "== Checking XcodeGen =="
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
  brew install xcodegen
fi

echo "== Git credentials =="
# The build repo is password-protected; store the login in the macOS Keychain so the
# background agent can fetch without prompting.
[ -n "$(git config --global credential.helper || true)" ] || git config --global credential.helper osxkeychain
echo "If asked: username 'sidestore' and the git password from your credentials file."
GIT_TERMINAL_PROMPT=1 git ls-remote "$URL" HEAD >/dev/null || { echo "Could not log in to $URL"; exit 1; }

echo "== Store upload token =="
# Kept in the login Keychain, not in a file. Re-run install.sh to change it.
if security find-generic-password -s stark-upload-token -w >/dev/null 2>&1; then
  echo "already in Keychain (service: stark-upload-token)"
else
  read -r -s -p "Paste the SIDESTORE upload token (input hidden): " TOK; echo
  [ -n "$TOK" ] || { echo "No token entered"; exit 1; }
  security add-generic-password -a "$USER" -s stark-upload-token -w "$TOK" -U
  unset TOK
fi

echo "== Cloning build repo =="
mkdir -p "$BASE/logs"
if [ ! -d "$BASE/repo/.git" ]; then git clone --branch "$BRANCH" "$URL" "$BASE/repo"; fi
git -C "$BASE/repo" rev-parse "origin/$BRANCH" > "$BASE/last-built-sha"
echo "baseline: $(cut -c1-8 "$BASE/last-built-sha") (only commits after this get built)"

echo "== Installing agent =="
cp "$HERE/stark-mac-builder.sh" "$BASE/stark-mac-builder.sh"
chmod +x "$BASE/stark-mac-builder.sh"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$BASE/stark-mac-builder.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>STARK_BRANCH</key><string>$BRANCH</string></dict>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$BASE/logs/launchd.out</string>
  <key>StandardErrorPath</key><string>$BASE/logs/launchd.err</string>
</dict></plist>
PL
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo
echo "Installed. Watching $BRANCH every 60s."
echo "  Activity log : tail -f $BASE/logs/agent.log"
echo "  Stop         : launchctl bootout gui/\$(id -u)/$LABEL"
echo "  Force rebuild of an app: git commit a change under that app's folder."
