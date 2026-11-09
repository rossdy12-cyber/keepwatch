# RetroDeck

Native iPhone library and controller preview. **Not a playable emulator yet.**

## Implemented
- Files-based ROM import, local JSON library, search and system filters.
- Game Controller connection detection and live extended-gamepad input diagnostics, intended for USB-C Backbone testing.
- XcodeGen project and GitHub Actions unsigned device IPA packaging.

## Not implemented
- RetroArch/libretro core integration, gameplay, audio/video output, save states, fast-forward, remapping, screenshots or touch controls.
- PS2, archive extraction and multi-file PS1 disc import.
- Controller/device compatibility has not been tested. No guarantee for iOS beta or LiveContainer compatibility.

## Build and install
Actions → Build RetroDeck unsigned IPA → Run workflow. Pushes to main also trigger builds and may consume macOS Actions minutes. Download RetroDeck-unsigned-IPA, extract the ZIP and import RetroDeck.ipa into SideStore for signing. No Apple certificate secrets are used by this workflow. A successful build is not proof of gameplay support.

Local: install XcodeGen, run `xcodegen generate`, open RetroDeck.xcodeproj. For device installation, configure your own signing.

## Imports
NES .nes; SNES .sfc/.smc; Mega Drive .md/.gen; N64 .z64/.n64/.v64; Nintendo DS .nds; PS1 .chd. These are catalogue labels only, not tested emulator compatibility. Import only content you have the right to use. No ROMs, BIOS files, keys or proprietary SDKs are included.

## Next stage
Select and audit upstream emulator cores and their licenses, integrate one playable core first, then validate video/audio, controller mapping and saves on hardware before expanding systems. Preserve upstream attribution and satisfy applicable source-distribution requirements. This project is not affiliated with RetroArch or Backbone.
