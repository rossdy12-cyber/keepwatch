#!/usr/bin/env bash
# Builds Lumen (app + Controls extension) UNSIGNED on the Codemagic M2, then posts the IPA to TrueNAS for 365-day
# concrete signing (G42YL9QS8W.app.lumen.camera). Uploads the build log either way so failures are diagnosable.
set -uo pipefail

STORE_URL="https://navidrome.nas-server.co.uk"
TOKEN="ss-deploy-9f8e7d6c5b4a3f2e1d0c"
VERSION="1.2.0"
BUNDLE_ID="app.lumen.camera"

cd "$(dirname "$0")"   # -> lumen/
LOG=/tmp/lumen_build.log

set +e
(
  set -e
  command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
  xcodegen generate
  xcodebuild \
    -project Lumen.xcodeproj \
    -target Lumen \
    -configuration Release \
    -sdk iphoneos \
    SYMROOT="$PWD/build" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    build
  rm -rf out && mkdir -p out/Payload
  cp -R build/Release-iphoneos/Lumen.app out/Payload/
  ( cd out && zip -qry Lumen.ipa Payload )
) > "$LOG" 2>&1
BUILD_STATUS=$?

tail -c 5000 "$LOG" || true
# Errors at the END so they survive the server-side tail-truncation of the build log.
{ echo "----- context (last 25 lines) -----"; tail -n 25 "$LOG"; echo; echo "===== SWIFT ERRORS ====="; grep -E "error:" "$LOG" | tail -n 50; echo "===== END ERRORS ====="; } > /tmp/lumen_tail.log 2>/dev/null
curl -fsSL -X POST -H "X-Upload-Token: $TOKEN" --data-binary @/tmp/lumen_tail.log \
  "$STORE_URL/sidestore-api/upload?buildLog=1" || true

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "BUILD FAILED ($BUILD_STATUS)"
  exit "$BUILD_STATUS"
fi

echo "=== Upload to TrueNAS for concrete signing ==="
curl -fsSL -X POST \
  -H "X-Upload-Token: $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @out/Lumen.ipa \
  "$STORE_URL/sidestore-api/upload?bundleId=${BUNDLE_ID}&version=${VERSION}&name=Lumen&notes=Pro+camera+%26+editor" \
  | tee out/publish.json
echo
curl -fsSL "$STORE_URL/sidestore-api/verify-ipa?bundleId=${BUNDLE_ID}" || true
echo
