#!/usr/bin/env bash
# Builds the Stark Face Apple Watch app (with its complications), unsigned.
#   Default: watch-only app -> out/StarkFace.ipa, for watchsign.exe + watch-devmode/watch_install.py.
#   COMPANION_ID=<iOS bundle id>: builds it to sit inside that iPhone app (Watch/StarkFace.app), which is
#   how the Stark Store installs it; build-and-publish.sh uses this mode.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=stark-watch
OUT=stark-watch/out
APP="$OUT/Payload/StarkFace.app"
EXT="$APP/PlugIns/StarkFaceWidgets.appex"
COMPANION_ID="${COMPANION_ID:-}"
if [ -n "$COMPANION_ID" ]; then BUNDLE_ID="$COMPANION_ID.watchkitapp"; else BUNDLE_ID="com.ross.starkface.watchonly"; fi
VERSION="1.0.0"
BUILD="$(date +%Y%m%d%H%M)"
rm -rf "$OUT" && mkdir -p "$EXT"

SDK_VERSION=$(xcrun --sdk watchos --show-sdk-version)
SDK_BUILD=$(xcrun --sdk watchos --show-sdk-build-version)
echo "watchOS SDK $SDK_VERSION ($SDK_BUILD)"

compile() { # output, extra flags, sources...
  local out=$1 flags=$2; shift 2
  xcrun --sdk watchos swiftc -target arm64-apple-watchos10.0 -O -parse-as-library $flags "$@" -o "${out}_arm64"
  if xcrun --sdk watchos swiftc -target arm64_32-apple-watchos10.0 -O -parse-as-library $flags "$@" -o "${out}_arm64_32" 2>/dev/null; then
    lipo -create "${out}_arm64" "${out}_arm64_32" -output "$out" && rm -f "${out}_arm64" "${out}_arm64_32"
  else
    mv "${out}_arm64" "$out"
  fi
}

compile "$APP/StarkFace" "" $SRC/StarkWatch/StarkWatchApp.swift
compile "$EXT/StarkFaceWidgets" "-application-extension" $SRC/StarkWatchWidgets/StarkWatchWidgets.swift

platform_keys() {
  cat <<KEYS
  <key>CFBundleSupportedPlatforms</key><array><string>WatchOS</string></array>
  <key>DTPlatformName</key><string>watchos</string>
  <key>DTPlatformVersion</key><string>$SDK_VERSION</string>
  <key>DTSDKName</key><string>watchos$SDK_VERSION</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>MinimumOSVersion</key><string>10.0</string>
  <key>UIDeviceFamily</key><array><integer>4</integer></array>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
KEYS
}

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Stark Face</string>
  <key>CFBundleName</key><string>StarkFace</string>
  <key>CFBundleExecutable</key><string>StarkFace</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
$(platform_keys)
  <key>WKApplication</key><true/>
$(if [ -n "$COMPANION_ID" ]; then echo "  <key>WKCompanionAppBundleIdentifier</key><string>$COMPANION_ID</string>"; else echo "  <key>WKWatchOnly</key><true/>"; fi)
  <key>WKRunsIndependentlyOfCompanionApp</key><true/>
  <key>WKBackgroundModes</key>
  <array><string>mindfulness</string></array>
  <key>CFBundleURLTypes</key>
  <array><dict><key>CFBundleURLName</key><string>com.ross.starkface</string><key>CFBundleURLSchemes</key><array><string>starkface</string></array></dict></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHealthShareUsageDescription</key><string>Stark Face shows your latest glucose reading and heart rate.</string>
</dict>
</plist>
PLIST

cat > "$EXT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>Stark Face Widgets</string>
  <key>CFBundleName</key><string>StarkFaceWidgets</string>
  <key>CFBundleExecutable</key><string>StarkFaceWidgets</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.widgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
$(platform_keys)
  <key>NSExtension</key>
  <dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

plutil -lint "$APP/Info.plist" "$EXT/Info.plist"
if [ -z "$COMPANION_ID" ]; then
  (cd "$OUT" && zip -qry StarkFace.ipa Payload)
  ls -lh "$OUT/StarkFace.ipa"
fi
