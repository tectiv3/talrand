# Talrand — Setup-loop / "data wipe" post-mortem (2026-06-27)

## Symptom

After the iCloud-backup work shipped, the app got stuck on the setup screen on
every launch ("Setting up your deck… 68/68", frozen on the last card), re-fetching
from Scryfall and hitting 429 rate limits. It looked like the SwiftData store had
been wiped.

## Root cause (confirmed via simulator + device logs)

**The iCloud entitlement made SwiftData try to use a CloudKit-backed store, which
the model doesn't satisfy, so the container silently fell back to in-memory.**

Detail:
- `f34d844` added the iCloud entitlement (for the iCloud Drive JSON backup). A plain
  `.modelContainer(for:)` defaults to `cloudKitDatabase: .automatic`, which enables
  CloudKit whenever an iCloud container entitlement is present.
- The model is not CloudKit-compatible. The on-device CoreData error was explicit:

  ```
  CoreData: error: Store failed to load.
  CloudKit integration requires that all relationships have an inverse, the following do not:
      Card: rulings, Deck: cards, Deck: commander, DeckEntry: card
  SwiftData: Unresolved error loading container … Code=134060
  ```

- `loadPersistentStores` failed → SwiftData fell back to an **in-memory** container
  (`isStoredInMemoryOnly == true`, `url == null`, verified by instrumentation).
- Consequences of the in-memory store:
  - The real on-disk deck was never loaded → `@Query` saw **0 decks** → `ContentView`
    stayed on `SetupView`.
  - `performSetup` created a shell, fetched cards, set `setupComplete = true` — but on
    the in-memory deck the UI's `@Query` never saw, so the view never advanced. The
    "stuck on the last card at 68/68" was just the loop finishing while the view
    physically could not switch. **There was no separate last-card fetch bug.**
  - Nothing persisted, so it re-ran full setup every launch, hammering Scryfall → 429s.

The data was **never lost**. The on-disk store stayed intact the whole time
(1 deck, `setupComplete=1`, 71 cards, commander Talrand). `customImagePath` removal
and "schema migration" were **red herrings** — lightweight migration drops that
column fine once the store actually loads.

## Fix (shipped this session)

1. **`TalrandApp.swift`** — explicit `ModelContainer` with
   `ModelConfiguration(schema:, cloudKitDatabase: .none)`. Keeps the iCloud Drive
   entitlement (for the JSON backup) but stops SwiftData from attempting CloudKit.
   `fatalError` on container-creation failure, so it can **never silently fall back
   to in-memory again** (a visible crash beats silent data loss).
2. **`SetupView.swift`** — setup screen no longer auto-fetches. First offers
   "Continue with Default Deck" / "Restore from Backup…" (fileImporter →
   `BackupCodec.decode` → `BackupService.restore` → fetch). Doubles as the recovery
   entry point. Added "Skip All Remaining" on the error screen.
3. **`SetupService.swift`** — `skipAllRemaining()` auto-skips every subsequent fetch
   failure without prompting (no more one-tap-per-failing-card).
4. **`ScryfallAPI.swift`** — 429 handling: honor `Retry-After`, else exponential
   backoff (0.5→1→2→4s, 4 tries) before failing; request spacing 50ms → 100ms.
5. **`CardDetailView.swift`** — opening a card with no image lazily re-fetches its
   data on demand (spinner), spreading load instead of batch-hammering the API.

Verified: simulator loads the real device store straight to the deck; restore path
works on device; 23 unit tests pass.

## Rule going forward

Adding an iCloud container entitlement opts a default SwiftData container into
CloudKit. If you don't want CloudKit sync, set `cloudKitDatabase: .none` explicitly,
and never let container creation fail silently — `fatalError` or surface it.

## Backups in `recovery/` (gitignored, NOT committed)

`recovery/` holds the user's intact deck (store + `talrand-backup.json` + cached
images) pulled during the incident. Kept local for safety; never commit.
