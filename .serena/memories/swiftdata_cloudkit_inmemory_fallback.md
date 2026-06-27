## SwiftData + iCloud entitlement → silent in-memory fallback (root cause of the 2026-06-27 setup loop)

**Symptom:** app stuck on setup screen every launch ("68/68", frozen on last card),
re-fetching from Scryfall, hitting 429s. Looked like the store was wiped.

**Actual root cause:** the iCloud entitlement (added in `f34d844` for the iCloud
Drive JSON backup) made SwiftData default to a **CloudKit-backed** store
(`.modelContainer(for:)` ⇒ `cloudKitDatabase: .automatic`). The model is NOT
CloudKit-compatible, so `loadPersistentStores` failed (CoreData Code=134060,
"relationships require an inverse": `Card.rulings`, `Deck.cards`, `Deck.commander`,
`DeckEntry.card`) and SwiftData **silently fell back to an in-memory container**
(`isStoredInMemoryOnly==true`, `url==null`). Consequences: real on-disk deck never
loaded → `@Query` saw 0 decks → never left `SetupView`; `setupComplete=true` was set
on an in-memory deck the UI never saw; nothing persisted → full re-setup every launch.

The data was never lost — on-disk store stayed intact (1 deck, setupComplete=1, 71
cards). `customImagePath` removal / "schema migration wipe" were red herrings.

**Fix:** explicit `ModelContainer(for: schema, configurations: ModelConfiguration(schema:, cloudKitDatabase: .none))`
in `TalrandApp`, plus `fatalError` on container-creation failure so it can never
silently fall back to in-memory again.

**Rules:**
- Adding an iCloud container entitlement opts a default SwiftData container into
  CloudKit. If you don't want CloudKit sync, set `cloudKitDatabase: .none` explicitly.
- Never let `ModelContainer` creation fail silently — `fatalError` or surface it; a
  visible crash beats a silent in-memory fallback that masquerades as data loss.
- Diagnose container issues by logging `modelContext.container.configurations.first`
  (`isStoredInMemoryOnly`, `url`); device logs readable via `idevicesyslog`
  (nix `libimobiledevice`) or seeding the real store into the simulator.

Related: [[swiftdata_defaults]] (separate, still-valid rule about defaulting new properties).
