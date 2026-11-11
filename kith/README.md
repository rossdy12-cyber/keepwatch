# Kith — your customizable AI companions

A Tolan-style companion app where **you design the character** — how it looks *and* who it is — and can keep
several. Each companion is a cute animated creature you chat with (text or voice); it speaks back and remembers
you, with its own personality and its own separate memory.

- **Design the creature:** body shape, colour, eyes, mouth and accessories — a live procedural creature (no art
  assets), animated (blinks, bobs, talks while speaking, pulses while listening).
- **Give it a personality:** role, vibe, traits, a name it calls you, a backstory, and a voice.
- **Chat with voice:** type or hold the mic; your companion replies and speaks aloud in its voice.
- **It remembers:** each companion builds its own memory of you over time (see *What they remember*).
- **Many companions:** create as many as you like; each is a separate character with separate memory.

## The brain
Kith thinks using **your own jarvis-core** (Settings → Jarvis core address + optional token). One core hosts all
your companions: the app sends each character's personality and a per-companion memory scope, so they stay in
character and remember you separately. (Needs jarvis-core with the `persona`/`scope` support — the version that
ships alongside this app.)

## Build & install (Stark / Codemagic / TrueNAS)
`codemagic.yaml` builds an unsigned IPA on Codemagic M2 and posts it to TrueNAS, which signs it with the 365-day
`G42YL9QS8W.app.kith.client` entitlements and publishes an OTA install link. Merge the `kith` workflow into the
store repo's root `codemagic.yaml` and commit `kith/` alongside it.
