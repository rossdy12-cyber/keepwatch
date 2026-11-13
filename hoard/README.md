# Hoard

A gothic black-and-crimson companion for your Steam account.

- **Hoard:** your whole library as box art, sorted by recently played, most played or name, plus the **Pile of Shame** (games never played). Search by name. Games you've played in the last two weeks glow.
- **Game pages:** playtime, last played, the current UK store price and discount, and every achievement ("Trophies") with unlock dates and how rare each one is.
- **Coven:** friends, with who's online and what they're playing.
- **Covet:** your wishlist with current UK prices, biggest discounts first.
- **Sanctum:** your profile, level and library totals.

## Setup

1. Get a Steam Web API key at <https://steamcommunity.com/dev/apikey>. Any domain name works (for example `localhost`).
2. In Steam → your name → **Profile → Edit Profile → Privacy Settings**, set **Game details** and **Friends list** to **Public**. Steam's API can't see them otherwise.
3. Build with **Actions → Build Hoard IPA**, install **Hoard-ipa** with Sideloadly, and enter your key and profile link (or custom URL name, or 17-digit ID).

The key stays in the iPhone Keychain. Hoard talks only to Steam.
