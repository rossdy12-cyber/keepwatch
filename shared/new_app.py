"""Scaffolds a gothic app: folder, project.yml, asset catalog with icon, and a GitHub Actions workflow.
Usage: python3 shared/new_app.py <Name> <folder> <icon letter> [extra Info.plist YAML file]"""
import json, os, subprocess, sys
from pathlib import Path

name, folder, letter = sys.argv[1], sys.argv[2], sys.argv[3]
extra = Path(sys.argv[4]).read_text() if len(sys.argv) > 4 else ""
root = Path(__file__).resolve().parent.parent
app = root / folder
assets = app / name / "Resources" / "Assets.xcassets"
for sub in ("AppIcon.appiconset", "AccentColor.colorset", "LaunchBackground.colorset"):
    (assets / sub).mkdir(parents=True, exist_ok=True)
info = {"info": {"author": "xcode", "version": 1}}
(assets / "Contents.json").write_text(json.dumps(info, indent=2))
def color(r, g, b):
    return json.dumps({"colors": [{"color": {"color-space": "srgb", "components": {"alpha": "1.000", "red": r, "green": g, "blue": b}}, "idiom": "universal"}], **info}, indent=2)
(assets / "AccentColor.colorset/Contents.json").write_text(color("0.769", "0.118", "0.227"))
(assets / "LaunchBackground.colorset/Contents.json").write_text(color("0.035", "0.020", "0.027"))
(assets / "AppIcon.appiconset/Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], **info}, indent=2))
subprocess.run([sys.executable, str(root / "shared/make_icon.py"), letter, str(assets / "AppIcon.appiconset/AppIcon.png")], check=True)

bundle = "app.keepwatch." + folder.replace("-", "")
extra_block = "".join("        " + line + "\n" for line in extra.splitlines() if line.strip())
(app / "project.yml").write_text(f"""name: {name}
options:
  bundleIdPrefix: app.keepwatch
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.0"
    SWIFT_STRICT_CONCURRENCY: minimal
    MARKETING_VERSION: "1.0.0"
    CURRENT_PROJECT_VERSION: "1"

targets:
  {name}:
    type: application
    platform: iOS
    sources:
      - path: {name}
      - path: ../shared/GothicKit
    settings:
      base:
        PRODUCT_NAME: {name}
        PRODUCT_BUNDLE_IDENTIFIER: {bundle}
        TARGETED_DEVICE_FAMILY: "1"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: ""
        CODE_SIGNING_REQUIRED: "NO"
        CODE_SIGNING_ALLOWED: "NO"
        DEVELOPMENT_TEAM: ""
    info:
      path: {name}/Info.plist
      properties:
        CFBundleDisplayName: {name}
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSRequiresIPhoneOS: true
        ITSAppUsesNonExemptEncryption: false
        UILaunchScreen:
          UIColorName: LaunchBackground
        UIUserInterfaceStyle: Dark
        UIAppFonts:
          - UnifrakturMaguntia-Book.ttf
          - Cinzel.ttf
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
{extra_block}""")

workflow = root / f".github/workflows/build-{folder}-ipa.yml"
workflow.write_text(f"""name: Build {name} IPA

on:
  workflow_dispatch:
  push:
    branches: [main, "claude/**"]
    paths:
      - "{folder}/**"
      - "shared/GothicKit/**"
      - ".github/workflows/build-{folder}-ipa.yml"

jobs:
  build:
    runs-on: macos-15
    timeout-minutes: 45

    steps:
      - name: Check out the code
        uses: actions/checkout@v4

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate {name} Xcode project
        working-directory: {folder}
        run: xcodegen generate

      - name: Build unsigned {name} app
        working-directory: {folder}
        run: |
          set -o pipefail
          xcodebuild \\
            -project {name}.xcodeproj \\
            -target {name} \\
            -configuration Release \\
            -sdk iphoneos \\
            SYMROOT="$PWD/build" \\
            CODE_SIGNING_ALLOWED=NO \\
            CODE_SIGNING_REQUIRED=NO \\
            CODE_SIGN_IDENTITY="" \\
            build

      - name: Package unsigned IPA
        working-directory: {folder}
        run: |
          mkdir -p out/Payload
          cp -R build/Release-iphoneos/{name}.app out/Payload/
          cd out
          zip -qry {name}.ipa Payload
          ls -lh {name}.ipa

      - name: Upload {name} IPA
        uses: actions/upload-artifact@v4
        with:
          name: {name}-ipa
          path: {folder}/out/{name}.ipa
          retention-days: 30
""")
print("scaffolded", app)
