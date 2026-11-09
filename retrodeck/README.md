# RetroDeck

Playable multi-system iPhone retro emulator with **Libretro Core Integration**, **Offline 60 FPS Native Arcade Engine**, **Save States**, **Audio/Video Shaders**, **Backbone USB-C Button Remapping**, and **Haptic On-Screen Touch Controls**.

## Features
- **Libretro Core Runtime (`retrodeck://` Custom URL Scheme + WebAssembly Core Bridge)**:
  - **NES**: `fceumm` (`.nes`, `.fds`, `.zip`)
  - **SNES**: `snes9x` (`.sfc`, `.smc`)
  - **Game Boy Advance**: `mgba` (`.gba`)
  - **Game Boy / Color**: `gambatte` (`.gb`, `.gbc`)
  - **Sega Mega Drive / Genesis**: `genesis_plus_gx` (`.md`, `.gen`, `.smd`, `.bin`)
  - **Nintendo 64**: `mupen64plus_next` (`.z64`, `.n64`, `.v64`)
  - **Nintendo DS**: `melonds` (`.nds`)
  - **PlayStation 1**: `pcsx_rearmed` (`.chd`, `.pbp`, `.iso`, `.cue`)
- **Built-in Offline 60 FPS Homebrew Engine & Starter Games**:
  - Includes 4 pre-installed playable 60 FPS homebrew arcade games (*Neon Cyber Pong DX*, *Starfield Invaders 60FPS*, *Hyper Breakout Synth*, and *Matrix Grid Runner*) with real-time `AVAudioEngine` square-wave chiptune audio synthesis.
- **Save States (4 Manual Slots + Quick Save / Quick Load)**:
  - Capture and restore binary save states per game directly to `Documents/SaveStates/`.
  - Bind physical controller buttons (e.g., `L3` / `R3`) to instant **Quick Save** and **Quick Load**.
- **Audio & Video Output Controls**:
  - Toggleable **CRT Scanline Overlay**, **Crisp Pixel**, and **Smooth Bilinear** modes.
  - Aspect Ratio switcher (`4:3 Original`, `16:9 Widescreen`, `Pixel Perfect`).
  - **Fast-Forward (`1x` / `2x`)** and **Audio Mute** controls in the in-game HUD bar.
- **Backbone USB-C & MFi Controller Remapping**:
  - Full persistent button mapping in the **Controller** tab (`ButtonMappingStore`) for every retro action (`D-Pad`, `A`, `B`, `X`, `Y`, `Start`, `Select`, `L1`, `R1`, `L2`, `R2`, `Quick Save`, `Quick Load`, `Fast Forward`).
  - Live hardware diagnostics for D-Pad, face buttons, triggers, and analog thumbsticks.
- **On-Screen Touch Controller Overlay**:
  - Multi-touch 8-way D-Pad, `A/B/X/Y` diamond, `L1/L2/R1/R2` shoulder triggers, and `SELECT/START` with haptic feedback (`UIImpactFeedbackGenerator`), opacity slider, and automatic hide when a Backbone controller is connected.
- **BIOS Manager**:
  - Import and verify optional BIOS files (`scph5501.bin`, `bios7.bin`, `bios9.bin`, `firmware.bin`) in the **Saves & BIOS** tab.
