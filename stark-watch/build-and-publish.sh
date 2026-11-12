#!/usr/bin/env bash
# Builds Stark Face for the Stark Store: the iPhone wrapper (Xcode) with the Watch app (build.sh) inside
# StarkFace.app/Watch/, unsigned. Then posts the IPA to TrueNAS for concrete signing and OTA publishing.
# After installing from the store, iOS offers the Watch app in the iPhone's Watch app > Available Apps.
set -uo pipefail

STORE_URL="https://navidrome.nas-server.co.uk"
# NO_UPLOAD=1 builds the IPA (out_store/StarkFace.ipa) without publishing, e.g. on CI without the token.
NO_UPLOAD="${NO_UPLOAD:-0}"
if [ "$NO_UPLOAD" = 1 ]; then TOKEN=""; else TOKEN="${SIDESTORE_UPLOAD_TOKEN:?set SIDESTORE_UPLOAD_TOKEN}"; fi
VERSION="1.0.0"
BUNDLE_ID="com.ross.starkface"

cd "$(dirname "$0")"   # -> stark-watch/
LOG=/tmp/starkface_build.log

set +e
(
  set -e
  command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
  xcrun --sdk watchos --show-sdk-version >/dev/null || { echo "error: watchOS SDK not installed (Xcode > Settings > Components)"; exit 1; }

  # 1. Watch app, built to live inside the iPhone app.
  COMPANION_ID="$BUNDLE_ID" bash ./build.sh

  # 2. iPhone wrapper.
  xcodegen generate
  xcodebuild \
    -project StarkFace.xcodeproj \
    -target StarkFace \
    -configuration Release \
    -sdk iphoneos \
    SYMROOT="$PWD/build" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build

  # 3. Embed the Watch app and package.
  rm -rf pkg && mkdir -p pkg/Payload
  cp -R build/Release-iphoneos/StarkFace.app pkg/Payload/
  mkdir -p pkg/Payload/StarkFace.app/Watch
  cp -R out/Payload/StarkFace.app pkg/Payload/StarkFace.app/Watch/StarkFace.app
  echo "--- bundle layout ---"
  find pkg/Payload -maxdepth 4 -name "*.app" -o -maxdepth 6 -name "*.appex" | sed 's|^| |'
  for p in pkg/Payload/StarkFace.app/Info.plist pkg/Payload/StarkFace.app/Watch/StarkFace.app/Info.plist \
           pkg/Payload/StarkFace.app/Watch/StarkFace.app/PlugIns/StarkFaceWidgets.appex/Info.plist; do
    echo "$p: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$p")"
  done
  rm -rf out_store && mkdir -p out_store
  ( cd pkg && zip -qry ../out_store/StarkFace.ipa Payload )
  ls -lh out_store/StarkFace.ipa
) > "$LOG" 2>&1
BUILD_STATUS=$?

tail -c 5000 "$LOG" || true
grep -E "error:|warning:|BUILD FAILED|BUILD SUCCEEDED|\.swift:[0-9]|bundle layout|Info.plist:" "$LOG" | tail -n 120 > /tmp/starkface_tail.log 2>/dev/null
tail -n 60 "$LOG" >> /tmp/starkface_tail.log 2>/dev/null
if [ "$NO_UPLOAD" != 1 ]; then
  curl -fsSL -X POST -H "X-Upload-Token: $TOKEN" --data-binary @/tmp/starkface_tail.log \
    "$STORE_URL/sidestore-api/upload?buildLog=1" || true
fi

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "BUILD FAILED ($BUILD_STATUS)"
  exit "$BUILD_STATUS"
fi
[ "$NO_UPLOAD" = 1 ] && { echo "NO_UPLOAD=1: built out_store/StarkFace.ipa, not publishing"; exit 0; }

echo "=== Upload to TrueNAS for concrete signing ==="
curl -fsSL -X POST \
  -H "X-Upload-Token: $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @out_store/StarkFace.ipa \
  "$STORE_URL/sidestore-api/upload?bundleId=${BUNDLE_ID}&version=${VERSION}&name=Stark+Face&notes=Watch+face+with+Stark+complications" \
  | tee out_store/publish.json
echo
curl -fsSL "$STORE_URL/sidestore-api/verify-ipa?bundleId=${BUNDLE_ID}" || true
echo
