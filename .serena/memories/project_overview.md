## Talrand — Project Overview

Talrand is a personal SwiftUI **iPhone app** for mid-game quick reference of the user's *Talrand, Sky Summoner* Commander (MTG) deck. About half the physical cards are Japanese, so the app provides fast English lookups, OCR scanning, and rulings. Previously named "MTG Blue", renamed to "Talrand" on 2026-06-16.

**Purpose / scope:** personal use only. No backend, no distribution. Prioritize mid-game speed and offline reliability. Scope is limited to personal deck reference + card swap — do not expand beyond that.

**Key facts:**
- Bundle ID: `com.talrand.app`
- Moxfield deck: `https://moxfield.com/decks/PLjXoRTzVkaTUkpO3rdimw` (Moxfield API needs curl-impersonate due to Cloudflare)
- 100 cards: 62 unique nonland + 37 Islands + 1 Commander
- Card data/images from Scryfall public API (no key). Offline-first: cached locally after first sync.
- Design specs: `docs/superpowers/specs/2026-06-16-mtg-blue-deck-companion-design.md` and `docs/superpowers/specs/2026-06-16-ocr-diagnostics-accuracy-design.md`

**Features:** camera card scanner (feature-print + OCR fallback), scan feedback, card detail (oracle text/rulings/mana/flip), swipe navigation, card swap via Scryfall, custom card photos, configurable thumbnails, offline-first.
