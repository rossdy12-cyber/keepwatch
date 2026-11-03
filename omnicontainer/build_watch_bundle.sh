#!/usr/bin/env bash
set -e

echo "Checking watchOS SDK..."
SDK_PATH=$(xcrun --sdk watchos --show-sdk-path 2>/dev/null || true)
if [ -z "$SDK_PATH" ]; then
  echo "watchOS SDK not found; skipping Watch bundle."
  exit 0
fi
echo "Found watchOS SDK at: $SDK_PATH"

APP_DIR="build/Release-iphoneos/OmniContainer.app/Watch/OmniWatch.app"
PLUGINS_DIR="$APP_DIR/PlugIns/OmniWatchWidgets.appex"
mkdir -p "$PLUGINS_DIR"

echo "Compiling OmniWatch (arm64 + arm64_32)..."
xcrun --sdk watchos swiftc \
  -target arm64-apple-watchos10.0 \
  -O \
  -parse-as-library \
  OmniWatch/OmniWatchApp.swift \
  -o "$APP_DIR/OmniWatch_arm64"

if xcrun --sdk watchos swiftc -target arm64_32-apple-watchos10.0 -O -parse-as-library OmniWatch/OmniWatchApp.swift -o "$APP_DIR/OmniWatch_arm64_32" 2>/dev/null; then
  lipo -create "$APP_DIR/OmniWatch_arm64" "$APP_DIR/OmniWatch_arm64_32" -output "$APP_DIR/OmniWatch"
  rm -f "$APP_DIR/OmniWatch_arm64" "$APP_DIR/OmniWatch_arm64_32"
else
  mv "$APP_DIR/OmniWatch_arm64" "$APP_DIR/OmniWatch"
fi

cat > "$APP_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>J.A.R.V.I.S.</string>
  <key>CFBundleExecutable</key>
  <string>OmniWatch</string>
  <key>CFBundleIdentifier</key>
  <string>com.ross.omnicontainer.watchkitapp</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>OmniWatch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>MinimumOSVersion</key>
  <string>10.0</string>
  <key>UIDeviceFamily</key>
  <array>
    <integer>4</integer>
  </array>
  <key>WKApplication</key>
  <true/>
  <key>WKCompanionAppBundleIdentifier</key>
  <string>com.ross.omnicontainer</string>
  <key>WKRunsIndependentlyOfCompanionApp</key>
  <true/>
  <key>WKBackgroundModes</key>
  <array>
    <string>self-care</string>
    <string>mindfulness</string>
    <string>workout-processing</string>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
  <key>NSHealthShareUsageDescription</key>
  <string>J.A.R.V.I.S. displays your live heart rate and steps on your custom Watch HUD.</string>
</dict>
</plist>
EOF

echo "Compiling OmniWatchWidgets.appex..."
xcrun --sdk watchos swiftc \
  -target arm64-apple-watchos10.0 \
  -O \
  -parse-as-library \
  -application-extension \
  OmniWatchWidgets/OmniWatchWidgets.swift \
  -o "$PLUGINS_DIR/OmniWatchWidgets_arm64"

if xcrun --sdk watchos swiftc -target arm64_32-apple-watchos10.0 -O -parse-as-library -application-extension OmniWatchWidgets/OmniWatchWidgets.swift -o "$PLUGINS_DIR/OmniWatchWidgets_arm64_32" 2>/dev/null; then
  lipo -create "$PLUGINS_DIR/OmniWatchWidgets_arm64" "$PLUGINS_DIR/OmniWatchWidgets_arm64_32" -output "$PLUGINS_DIR/OmniWatchWidgets"
  rm -f "$PLUGINS_DIR/OmniWatchWidgets_arm64" "$PLUGINS_DIR/OmniWatchWidgets_arm64_32"
else
  mv "$PLUGINS_DIR/OmniWatchWidgets_arm64" "$PLUGINS_DIR/OmniWatchWidgets"
fi

cat > "$PLUGINS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>J.A.R.V.I.S. Widgets</string>
  <key>CFBundleExecutable</key>
  <string>OmniWatchWidgets</string>
  <key>CFBundleIdentifier</key>
  <string>com.ross.omnicontainer.watchkitapp.widgets</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>OmniWatchWidgets</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>2.1.0</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>MinimumOSVersion</key>
  <string>10.0</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
EOF

codesign -f -s - "$PLUGINS_DIR"
codesign -f -s - "$APP_DIR"
echo "Successfully built and embedded Watch/OmniWatch.app + OmniWatchWidgets.appex!"
