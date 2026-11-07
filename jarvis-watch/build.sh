#!/usr/bin/env bash
# Builds J.A.R.V.I.S. Wrist OS as a stand-alone (watch-only) Apple Watch app: out/JarvisWatch.ipa
# (Payload/JarvisWatch.app with its complications). It's unsigned: sign it with watchsign.exe, then install it
# with watch-devmode/watch_install.py. The Swift sources are shared with OmniContainer's Watch app.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=omnicontainer
OUT=jarvis-watch/out
APP="$OUT/Payload/JarvisWatch.app"
EXT="$APP/PlugIns/JarvisWatchWidgets.appex"
BUNDLE_ID="com.ross.jarvis.watchkitapp"
VERSION="2.1.0"
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

compile "$APP/JarvisWatch" "" $SRC/OmniWatch/OmniWatchApp.swift
compile "$EXT/JarvisWatchWidgets" "-application-extension" $SRC/OmniWatchWidgets/OmniWatchWidgets.swift

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
  <key>CFBundleDisplayName</key><string>J.A.R.V.I.S.</string>
  <key>CFBundleName</key><string>JarvisWatch</string>
  <key>CFBundleExecutable</key><string>JarvisWatch</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
$(platform_keys)
  <key>WKApplication</key><true/>
  <key>WKWatchOnly</key><true/>
  <key>WKRunsIndependentlyOfCompanionApp</key><true/>
  <key>WKBackgroundModes</key>
  <array><string>self-care</string><string>mindfulness</string><string>workout-processing</string></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHealthShareUsageDescription</key><string>J.A.R.V.I.S. shows your live heart rate and steps on its Watch faces.</string>
</dict>
</plist>
PLIST

cat > "$EXT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>J.A.R.V.I.S. Widgets</string>
  <key>CFBundleName</key><string>JarvisWatchWidgets</string>
  <key>CFBundleExecutable</key><string>JarvisWatchWidgets</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.widgets</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
$(platform_keys)
  <key>NSExtension</key>
  <dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST

plutil -lint "$APP/Info.plist" "$EXT/Info.plist"
(cd "$OUT" && zip -qry JarvisWatch.ipa Payload)
ls -lh "$OUT/JarvisWatch.ipa"
