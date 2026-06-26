# Scanner regression suite (camera-free, runs on simulator)

`make test` runs `TalrandTests` (a **non-hosted** logic-test target — no app launch, no
SwiftData/network/camera). It replays physical-card fixture photos through the SAME
scanner logic the live camera runs, on the iOS Simulator. This is why OCR/resolution
*can* be tested in the simulator even though the **camera cannot** (see
[[device_debug_workflow]]).

## Shared seams (single source of truth — prod + tests use them)
- `Talrand/Services/ScanOCR.swift` — AVFoundation-free crop→OCR→parse: `detectCard`
  (rectangle+perspective), `collectorStrip`, `collectorReadout`, `titleText`,
  `typeReadout`, `nameLookup` (incl. DFC pre-"//" front-face split). `CameraService`
  delegates to it.
- `Talrand/Services/DeckResolver.swift` — pure generic; the `findCard` decision
  (set+number → unique; bare number → exactly-one, else nearestId/type tiebreak, else
  refuse). `CameraScannerView.findCard` delegates to it (data access injected as
  closures). Tests drive it from a bundled all-printings snapshot.

## Fixtures: `TalrandTests/Fixtures/`
Real JP cards. Ground truth (verified via Scryfall): Brainstorm CNS #91, Counterspell
MMQ #69, Docent of Perfection EMN **#56** (DFC), Crystal Shard TSR #393, Ravenform
KHM #72. `deck_index.json` = `{cards, printings}` deck snapshot the resolver runs against.

Known OCR-quality gaps are wrapped in strict `XCTExpectFailure` (suite stays green; each
flips to a hard failure once OCR/crop improves → forces wrapper removal): Crystal Shard
bare-number has no parser pattern; Docent strip OCRs illegibly; retro-frame/furigana
titles misread single kanji (渦→酒, 完→党) or read empty. These are OCR/crop limits, not
parser/matcher bugs. The Ravenform→Ponder false-positive is a **green guard**
(`testRavenformFixtureDoesNotResolveToPonder`).

## Refreshing the deck fixture from the real (post-swap) device deck
`deck_index.json` was bootstrapped from Scryfall but should be replaced with the actual
on-device deck. `DebugExport.deckIndex` (DEBUG-only, called from `ContentView.task`
after backfill) dumps current `Card`s + all `CollectorNumberEntry` rows to
`Documents/deck_index.json`. Pull it:
```
xcrun devicectl device copy from --device soPro --domain-type appDataContainer \
  --domain-identifier com.talrand.app --source Documents/deck_index.json \
  --destination TalrandTests/Fixtures/deck_index.json
```

Related: [[card_scanning]], [[device_debug_workflow]].
