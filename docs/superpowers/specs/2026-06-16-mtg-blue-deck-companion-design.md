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
| Network | URLSession | Scryfall + Moxfield API calls |
| Backend | None | Personal tool, all data from public APIs |

### Why not PWA

- iOS Safari camera access is unreliable for live OCR
- 50MB storage cap per origin makes offline caching fragile
- No native OCR — would require Tesseract.js (heavy, slow)
- Laravel backend is overkill with zero backend needs

## Data Sources

### Moxfield API

- Endpoint: `https://api2.moxfield.com/v3/decks/all/PLjXoRTzVkaTUkpO3rdimw`
- Returns full deck list with Scryfall IDs, set codes, collector numbers, oracle text, pricing
- Requires `curl-impersonate` level TLS fingerprinting (Cloudflare-protected) — **for development/import only**, not runtime
- The deck: "Talrand" by Vegetabrown, Commander format, 99 mainboard + 1 commander

### Scryfall API

- Card data: `https://api.scryfall.com/cards/{scryfall_id}`
- Rulings: `https://api.scryfall.com/cards/{scryfall_id}/rulings`
- Card images: Available via `image_uris` in card data
- Rate limit: 50ms between requests (respect this during bulk import)
- Bulk data endpoint available for initial seeding if needed

## Screens

### 1. Deck List

- Grid or list of all 100 cards with English thumbnail images
- Tap any card to open Card Detail
- Search/filter by card name
- Grouped by card type (Instant, Sorcery, Creature, Artifact, Enchantment, Land)
- Commander (Talrand) displayed prominently at top

### 2. Card Detail

- Full English card image (large)
- Oracle text (readable text, not just the image)
- Mana cost, type line, power/toughness (if creature)
- Official Scryfall rulings listed below
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
- Scryfall search field (by card name, requires network)
- Search results shown as list with card thumbnails
- Tap replacement card → confirm swap → old card removed, new card added
- New card's data, image, and rulings fetched and cached
- Returns to Deck List with updated entry

## Data Flow

### First Launch (Setup)

```
App Launch
  → Fetch deck from Moxfield API (or allow manual paste of deck list)
  → Parse card list (100 entries with Scryfall IDs)
  → For each card:
      → Fetch card data from Scryfall API (with 50ms rate limit delay)
      → Fetch rulings from Scryfall API
      → Download English card image
  → Persist all data to SwiftData
  → Cache images to disk
  → Build collector number → card lookup index
  → Ready
```

Total first-launch data: ~100 API calls + ~100 images. Approximately 2-3 minutes on reasonable WiFi.

### Mid-Game (Runtime)

```
Camera Active
  → AVFoundation captures frames
  → Vision OCR extracts text from collector number region
  → Parse set code + collector number (e.g., "6ED" + "61")
  → Look up in local SwiftData index
  → Match found → navigate to Card Detail
  → No network required
```

### Data Refresh

- Manual "refresh deck" button to re-fetch from Moxfield if the deck is modified
- No automatic sync needed (single deck, infrequent changes)

## Data Model (SwiftData)

```
Deck
  ├─ id: String (Moxfield public ID)
  ├─ name: String
  ├─ format: String
  ├─ lastSynced: Date
  │
  ├─ commander: Card
  └─ cards: [DeckEntry]

DeckEntry
  ├─ quantity: Int
  └─ card: Card

Card
  ├─ scryfallId: String
  ├─ name: String
  ├─ setCode: String
  ├─ collectorNumber: String
  ├─ oracleText: String
  ├─ manaCost: String
  ├─ typeLine: String
  ├─ power: String?
  ├─ toughness: String?
  ├─ rarity: String
  ├─ imageUrl: String
  ├─ localImagePath: String?
  └─ rulings: [Ruling]

Ruling
  ├─ date: String
  ├─ source: String
  └─ comment: String
```

## Collector Number OCR Strategy

MTG collector numbers appear at the bottom of every card in the format: `{number}/{total} · {set code}` or similar patterns depending on printing era.

- Use `VNRecognizeTextRequest` with `.accurate` recognition level
- Constrain recognition region to bottom 15% of camera frame (where collector info is printed)
- Parse recognized text for patterns matching: digits, slash, digits, and 2-4 letter set codes
- Match against the local deck index: `(setCode, collectorNumber) → Card`
- The deck only has 63 unique cards — the match space is small, so fuzzy matching is feasible if OCR is imprecise

## Scope Boundaries

### In scope (v1)
- Moxfield deck import
- Offline card data + image caching
- Camera OCR collector number scanning
- English card detail + rulings
- Deck list browsing with type grouping
- Single deck (Talrand)
- Card swap: remove a card from the deck, search Scryfall for a replacement, add it (auto-fetches data + image + rulings into local cache)

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
- Moxfield API requires TLS fingerprinting (Cloudflare) — handle in import flow, consider hardcoding deck data as fallback
- All card data cached locally after first sync
