#!/usr/bin/env bash
# Builds the Kith SwiftUI app UNSIGNED on the Codemagic M2, then posts the IPA to TrueNAS for 365-day concrete
# signing (G42YL9QS8W.app.kith.client). Uploads the build log either way so failures are diagnosable.
set -uo pipefail

STORE_URL="https://navidrome.nas-server.co.uk"
TOKEN="ss-deploy-9f8e7d6c5b4a3f2e1d0c"
VERSION="1.0.0"
BUNDLE_ID="app.kith.client"

cd "$(dirname "$0")"   # -> kith/
LOG=/tmp/kith_build.log

set +e
(
  set -e
  command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
  xcodegen generate
  xcodebuild \
    -project Kith.xcodeproj \
    -target Kith \
    -configuration Release \
    -sdk iphoneos \
    SYMROOT="$PWD/build" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build
  rm -rf out && mkdir -p out/Payload
  cp -R build/Release-iphoneos/Kith.app out/Payload/
  ( cd out && zip -qry Kith.ipa Payload )
) > "$LOG" 2>&1
BUILD_STATUS=$?

tail -c 5000 "$LOG" || true
# Upload the build-log tail for diagnosis (visible via the pipeline status).
grep -E "error:|warning:|BUILD FAILED|BUILD SUCCEEDED|\.swift:[0-9]|Compiling|ARCHIVE" "$LOG" | tail -n 120 > /tmp/kith_tail.log 2>/dev/null
tail -n 60 "$LOG" >> /tmp/kith_tail.log 2>/dev/null
curl -fsSL -X POST -H "X-Upload-Token: $TOKEN" --data-binary @/tmp/kith_tail.log \
  "$STORE_URL/sidestore-api/upload?buildLog=1" || true

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "BUILD FAILED ($BUILD_STATUS)"
  exit "$BUILD_STATUS"
fi

echo "=== Upload to TrueNAS for concrete signing ==="
curl -fsSL -X POST \
  -H "X-Upload-Token: $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @out/Kith.ipa \
  "$STORE_URL/sidestore-api/upload?bundleId=${BUNDLE_ID}&version=${VERSION}&name=Kith&notes=Kith+companion+app" \
  | tee out/publish.json
echo
curl -fsSL "$STORE_URL/sidestore-api/verify-ipa?bundleId=${BUNDLE_ID}" || true
echo
