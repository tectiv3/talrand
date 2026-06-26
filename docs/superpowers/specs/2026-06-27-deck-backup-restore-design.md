# Deck Backup & Restore — design

Captured 2026-06-27. Decided after reviewing the SwiftData schema and the
single-device / paid-account / "remove custom photos" constraints.

## Decision summary

- **Single device, paid Apple Developer account.**
- **CloudKit row-sync rejected.** SwiftData's CloudKit backend exists for
  continuous *multi-device* sync; on one device it adds no value over a backup,
  while costing a risky schema migration (every non-optional attribute needs a
  default; every relationship needs an inverse), a store split (to keep the
  re-downloadable Scryfall cache out of the synced DB), and iCloud provisioning.
- **Custom-photo feature removed** (see step 0). It's redundant with the
  printing-swap feature and removing it makes the backup pure JSON — no binary
  bundling, no zip.
- **Two-layer backup:**
  1. *Passive* — exclude the re-downloadable Scryfall image cache from device
     iCloud Backup (`isExcludedFromBackup`), so the SwiftData store + user data
     ride the device's existing iCloud Backup cheaply and restore on
     device-migration / full restore.
  2. *Active* — a versioned JSON snapshot auto-written to the app's **iCloud
     Drive container** (debounced), plus a manual **Export / Restore** in the
     deck gear menu. This survives a fresh app reinstall (which device backup
     does not) and is portable / shareable via Files.
- **Restore semantics: replace** (wipe user rows, rebuild from snapshot). Merge
  is deferred.

## Step 0 — Remove the custom-photo feature (prerequisite)

Deleting this first is what lets the snapshot stay pure JSON.

- `Card.swift`: remove `var customImagePath: String?`. (Optional attribute →
  SwiftData lightweight migration drops the column; no wipe.)
- `CardDetailView.swift`: remove `selectedPhoto`/`PhotosPicker`, the camera
  button, the `ImagePicker` `UIViewControllerRepresentable` + `Coordinator`, and
  the save/clear logic (`card.customImagePath = …` / `= nil`). The detail image
  source becomes just `localFrontImagePath` (and back).
- `CardThumbnail.swift`: drop the `customImagePath ?? ` fallbacks (2 sites).
- `ImageCacheService.swift`: remove `saveCustomImage` / `deleteCustomImage`.
- Orphaned `custom_*.jpg` files: leave them (harmless) or one-shot sweep on next
  launch. Not worth a migration.

## Snapshot format (v1)

A single `Codable` document. Versioned so an old export restores into a newer
schema (`version` field gates the decoder).

```
BackupV1 {
  version: 1
  exportedAt: ISO-8601 string        // stamped by the caller, not in-script
  deck: {
    id, name, format, setupComplete
    commanderScryfallId: String?
    entries: [{ scryfallId, quantity, board }]
  }
  cards: [{                          // only deck-referenced cards
    scryfallId, oracleId, name, setCode, collectorNumber,
    typeLine, printedName, lastScannedAt
  }]
}
```

- **Printing swaps are captured implicitly**: a swap replaces a `DeckEntry`'s
  `Card` with a different printing's `Card`, so serializing each entry's
  `scryfallId` + that card's `setCode`/`collectorNumber` *is* the swap state.
- **Included** because it's user-meaningful or slow to re-derive: deck
  composition, board (main/side), printing identity, `printedName` (backfilled
  JP names), `lastScannedAt` (History).
- **Excluded** because it's rebuildable from Scryfall: `rulings`, cached images
  (`localFront/BackImagePath`, `frontImageUrl`), the `CollectorNumberEntry`
  all-printings table, `oracleText`/`manaCost`/`rarity`/etc. (re-fetched per
  card on restore). Keeping the snapshot to identity fields keeps it tiny and
  schema-drift-resistant.

## Export

- Encode `BackupV1` from the live `Deck` + its entries' cards.
- Manual path: write to a temp file, present the document picker / share sheet
  (`fileExporter`) → user saves to Files / iCloud Drive / AirDrop.

## Restore

- Pick a `.json` via `fileImporter`; decode + validate `version`.
- **Replace**: delete existing `Deck`/`DeckEntry`/`Card` rows, then rebuild
  `Card`s (identity fields from snapshot, the rest left empty), `DeckEntry`s, and
  the `Deck` with its commander link.
- Kick off the existing setup/backfill pipeline to re-fetch card data, images,
  rulings, and rebuild the `CollectorNumberEntry` table from Scryfall (reuse
  `SetupService.performBackfill` / the initial-setup fetch).
- Guard: confirm before replacing (destructive).

## Auto-backup to the iCloud Drive container

- Resolve the container via
  `FileManager.default.url(forUbiquityContainerIdentifier:)` → `Documents/` →
  write `talrand-backup.json` (overwrite; single rolling snapshot).
- **Trigger**: debounced — write on `scenePhase == .background` and after known
  deck mutations (swap completed, setup finished). A debounce (e.g. coalesce to
  one write per few seconds) avoids thrashing. No need for SwiftData history
  tokens at v1; background + mutation hooks cover the cases that matter.
- iCloud syncs the file automatically; it also appears in the user's iCloud
  Drive (Files) for manual grab.

## Capabilities / entitlements (paid account)

- iCloud capability with **iCloud Documents** (not CloudKit).
- `com.apple.developer.icloud-container-identifiers` +
  `ubiquity-container-identifiers` = `iCloud.com.talrand.app`.
- Add to `project.yml` target entitlements; container must be provisioned on the
  developer account. `DEVELOPMENT_TEAM` already lives in the git-ignored
  `Local.xcconfig`.
- No background-modes / push entitlement needed (that's CloudKit, which we're
  not using).

## Build order

1. Step 0 — remove custom photos (independent cleanup; build + run green).
2. `BackupCodec` (encode/decode `BackupV1`) + unit tests (pure, no SwiftData) —
   round-trip a snapshot, reject a wrong `version`.
3. Manual Export (`fileExporter`) + Restore (`fileImporter` + replace + refetch)
   in the gear menu.
4. iCloud Documents entitlement + auto-write to the ubiquity container.
5. `isExcludedFromBackup` on the Scryfall cache directory.

## Open questions / deferred

- **Merge-on-restore** (vs replace): deferred. Replace is correct for
  restore-after-wipe; merge matters only if combining two devices' state, which
  single-device doesn't need yet.
- **Format versioning policy**: v1 decoder only; add migration shims when v2
  lands.
- **Multiple decks**: schema allows >1 `Deck` (`decks.first` is used today).
  v1 backs up the active deck; revisit if multi-deck becomes real.
