# MTG Blue — Talrand Deck Companion

## Overview

A native SwiftUI iPhone app for mid-game quick reference of a 100-card Commander deck (Talrand, Sky Summoner). Half the physical cards are in Japanese — the app provides instant English translations, oracle text, and official rulings via camera-based collector number scanning.

Personal tool, no backend, no distribution.

## Problem

1. Half the cards are in Japanese and unreadable
2. The user is new to MTG and doesn't know the deck's cards or interactions
3. Mid-game, there's no fast way to look up what a Japanese card does

## Core Use Case

During a Commander game, the user draws or encounters a Japanese card. They point their phone at the collector number printed on the card (always in Latin characters), and the app instantly shows the English card image, oracle text, and official rulings. No network required.

## Stack

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| UI | SwiftUI | Native iOS, fast iteration, declarative |
| OCR | Vision framework (`VNRecognizeTextRequest`) | On-device, offline, no ML training needed |
| Camera | AVFoundation | Full camera control, live preview |
| Persistence | SwiftData | Local-only, lightweight ORM |
| Network | URLSession | Scryfall API calls during setup |
| Backend | None | Personal tool, all data from public APIs |

### Why not PWA

- iOS Safari camera access is unreliable for live OCR
- 50MB storage cap per origin makes offline caching fragile
- No native OCR — would require Tesseract.js (heavy, slow)
- Laravel backend is overkill with zero backend needs

## Data Sources

### Bundled Deck Data

The Moxfield API (`api2.moxfield.com`) is behind Cloudflare and requires TLS fingerprinting that URLSession cannot perform. Instead, the deck list is **bundled as a static JSON asset** in the app, extracted once during development via `curl-impersonate`.

- Source deck: "Talrand" by Vegetabrown, Commander format
- Moxfield URL: `https://moxfield.com/decks/PLjXoRTzVkaTUkpO3rdimw`
- 99 mainboard cards + 1 commander = 100 cards (63 unique nonland, 37 Islands)
- Bundled JSON includes: Scryfall IDs, oracle IDs, set codes, collector numbers, card names
- Update path: user can paste a Moxfield text export to update the deck list (format: `1 Card Name (SET) CN`)

### Scryfall API

- Card data: `https://api.scryfall.com/cards/{scryfall_id}`
- All printings: `https://api.scryfall.com/cards/search?q=oracleid:{oracle_id}&unique=prints`
- Rulings: `https://api.scryfall.com/cards/{scryfall_id}/rulings`
- Card images: via `image_uris` (normal cards) or `card_faces[].image_uris` (double-faced cards)
- Rate limit: 50ms between requests (respect during bulk setup)

## Screens

### 1. Deck List

- Grid or list of all 100 cards with English thumbnail images
- Tap any card to open Card Detail
- Search/filter by card name
- Grouped by card type (Instant, Sorcery, Creature, Artifact, Enchantment, Land)
- Commander (Talrand) displayed prominently at top

### 2. Card Detail

- Full English card image (large); for double-faced cards, show front face with tap-to-flip
- Oracle text (readable text, not just the image)
- Mana cost, type line, power/toughness (if creature)
- Official Scryfall rulings listed below
- "Replace" action to initiate card swap
- Back button to return to Deck List or Camera

### 3. Camera Scanner

- Live camera preview (AVFoundation)
- Guide overlay indicating where to position the collector number (bottom of card)
- Vision OCR runs continuously on the collector number region
- On successful match against cached deck: jumps directly to Card Detail (no confirmation step)
- If no match found: brief "Card not in deck" indicator
- Manual fallback: button to switch to Deck List for manual lookup

### 4. Card Swap

- Accessed from Card Detail via "Replace" action
- Opens Camera Scanner in "swap mode" — scan the new physical card's collector number
- If the scanned card is already cached: confirm swap immediately
- If the scanned card is new: fetch data + image + rulings from Scryfall (requires network), then confirm
- On confirm: old card removed from deck, new card added
- Returns to Deck List with updated entry
- Fallback: Scryfall text search if the new card's collector number is unreadable

### 5. Setup / Import Progress

- Shown on first launch while card data is being fetched
- Progress bar: "Fetching card 34/63..." with card name
- Estimated time remaining
- Errors shown inline (e.g., "Failed to fetch Counterspell — Retry / Skip")
- If network drops mid-import: persists partial progress, resumes where it left off on next launch

## Data Flow

### First Launch (Setup)

```
App Launch
  → Load bundled deck JSON (card names, Scryfall IDs, oracle IDs)
  → For each unique card (63 cards):
      → Fetch card data from Scryfall API (50ms rate limit)
      → Fetch all printings via oracle ID (for collector number index)
      → Fetch rulings from Scryfall API
      → Download English card image (front face; both faces for DFCs)
  → Persist all data to SwiftData
  → Cache images to disk
  → Build collector number index: (setCode, collectorNumber) → cardName
  → Mark setup complete
  → Ready
```

Total first-launch data: ~189 API calls (63 card + 63 printings + 63 rulings) + ~65 images. Approximately 2-4 minutes on reasonable WiFi. Partial progress is saved — resumable on failure.

### Mid-Game (Runtime)

```
Camera Active
  → AVFoundation captures frames
  → Vision OCR extracts text from bottom region of frame
  → Parse collector number from OCR text (see OCR Strategy below)
  → Look up (setCode, collectorNumber) in local index → cardName
  → cardName found → navigate to Card Detail
  → No network required
```

### OCR Matching — Handling Different Printings

The physical cards may be different printings than what Moxfield lists. A Japanese Counterspell from a 2024 set has a different set code than the 6th Edition Counterspell in the Moxfield data. To handle this:

1. During setup, fetch all printings of each card via Scryfall's `oracleid` search
2. Build an index of ALL known (setCode, collectorNumber) pairs for every card in the deck
3. At scan time, match the OCR'd collector number against this expanded index
4. This means a Japanese Counterspell from *any* printing will match "Counterspell" in the deck

This covers the "physical cards differ from Moxfield listing" problem without needing network at runtime.

### Data Refresh

- Manual "update deck" action to paste a new Moxfield text export
- On update: diff against current deck, fetch only new cards, remove departed ones (and their cached images)
- No automatic sync

## Data Model (SwiftData)

```
Deck
  ├─ id: String (Moxfield public ID)
  ├─ name: String
  ├─ format: String
  ├─ lastSynced: Date
  ├─ setupComplete: Bool
  │
  ├─ commander: Card
  └─ cards: [DeckEntry]

DeckEntry
  ├─ quantity: Int
  └─ card: Card

Card
  ├─ scryfallId: String
  ├─ oracleId: String
  ├─ name: String
  ├─ setCode: String
  ├─ collectorNumber: String
  ├─ oracleText: String
  ├─ manaCost: String
  ├─ typeLine: String
  ├─ power: String?
  ├─ toughness: String?
  ├─ rarity: String
  ├─ layout: String (normal, transform, modal_dfc, prototype)
  ├─ frontImageUrl: String
  ├─ backImageUrl: String? (for DFCs)
  ├─ localFrontImagePath: String?
  ├─ localBackImagePath: String?
  └─ rulings: [Ruling]

CollectorNumberEntry (for the expanded scanning index)
  ├─ setCode: String
  ├─ collectorNumber: String
  └─ cardName: String (→ matches Card.name)

Ruling
  ├─ date: String
  ├─ source: String
  └─ comment: String
```

## Collector Number OCR Strategy

### Format Variance

The deck spans 41 different sets from 1997–2025. Collector number formatting varies:

- **Post-M15 (2014+)**: Set code and collector number clearly printed at bottom. Format: `SET · {number}/{total}` or `SET · {number}`. Most cards in the deck use this.
- **Pre-M15 (before 2014)**: Collector number present but no set code printed on card. Sets in deck: `5ed`, `6ed`, `tmp`, `jud`, `5dn`. Only the number (e.g., `61/350`) is readable from these.
- **The List (`plst`)**: Compound collector numbers like `MRD-159`. Printed with original set's formatting.

### Matching Strategy

1. Use `VNRecognizeTextRequest` with `.accurate` recognition level
2. Scan the bottom ~20% of the camera frame
3. Extract all recognized text, look for patterns:
   - 3-letter set code + number: `CMM 124`, `STX 37`
   - Number/total: `61/350`, `124/674`
   - Compound: `MRD-159`
4. Attempt match against the expanded collector number index (all printings of all deck cards)
5. For pre-M15 cards without set codes: match by collector number alone — within 63 unique cards the collision rate is manageable; if ambiguous, show both matches and let the user tap the right one
6. If no match: show "Card not found" with button to browse deck list

### Camera Permission

If camera permission is denied, the app still functions as a deck browser. The scanner tab shows a prompt to enable camera access in Settings, with a direct link to the Settings app.

## Scope Boundaries

### In scope (v1)
- Bundled deck data (extracted from Moxfield during development)
- Offline card data + image caching (all printings index)
- Camera OCR collector number scanning
- English card detail + rulings
- Double-faced card support (Docent of Perfection, Silundi Vision)
- Deck list browsing with type grouping
- Single deck (Talrand)
- Card swap via camera scan (remove old, scan new, fetch if needed)
- Setup progress UI with resume-on-failure
- Manual deck update via pasted text export

### Out of scope
- Full deck building (adding cards from scratch, changing commander, building new decks)
- Life counter
- Rules engine or game state tracking
- Multi-deck support
- Card synergy analysis
- App Store distribution
- User accounts or cloud sync
- Card price tracking
- Deck statistics / mana curve charts

## Technical Constraints

- iOS 17+ (Vision framework improvements, SwiftData)
- iPhone only (no iPad/Mac optimization)
- Scryfall API rate limit: 50ms between requests
- Moxfield API is not callable from URLSession (Cloudflare) — deck data bundled as static asset
- All card data cached locally after first sync
- Double-faced cards: images from `card_faces[].image_uris`, not top-level `image_uris`

## Known Cards with Special Layouts

| Card | Set | Layout | Notes |
|------|-----|--------|-------|
| Docent of Perfection // Final Iteration | emn #56 | transform | Two-sided, needs both face images |
| Silundi Vision // Silundi Isle | znr #80 | modal_dfc | MDFC, front is instant / back is land |
| Arcane Proxy | bro #75 | prototype | Single face but has prototype alternate casting cost |
