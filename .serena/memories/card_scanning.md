## How Talrand's Card Scanner Works (durable facts only)

The scanner (`CameraService` + `CameraScannerView`) recognizes a physical card per frame by **fusing several weak signals** — a foreign / different-printing card rarely lets any single signal clear its bar alone, so it fires on **corroboration**, not on one strong signal.

**Signals (pure logic in the testable seams `ScanOCR` + `DeckResolver` — see [[scanner_regression_tests]]):**
1. **Name** — `ScanOCR.titleText` OCRs the title bar (ja+en) → `CardNameMatcher` matches the deck's English names AND Japanese printed names (`Card.printedName`, incl. DFC front-face via the `" // "` split). Strongest; printing-independent.
2. **Feature-print** — `CardImageMatcher` art match; exposes nearest + runner-up ids even when too weak to fire on its own.
3. **Collector code** — `ScanOCR.collectorReadout` → `CollectorNumberParser` → `DeckResolver` (set+number trusted; bare number → exactly-one, else nearestId/type tiebreak, else refuse).
4. **Type** — `ScanOCR.typeReadout`.

**Firing (`CameraService.captureOutput`):**
- **Name + feature-print agree → fire immediately** (two independent recognitions of the same deck card; an out-of-deck card can't name-match, so it can't false-fire).
- **Name alone → window-voted** (2 votes within a window; a dropped/unreadable frame no longer resets progress).
- **Type "different-category" rule** — the OCR'd type confirms feature-print's nearest only when it *discriminates*: nearest matches the type and the runner-up does NOT (same-type confusables like Counterspell/Negate, both Instants, correctly fall through). Voted 2× and distance-guarded.
- **Feature-print strong standalone** (close + clear runner-up gap) and the **collector/DeckResolver** path remain as fallbacks.

**Hard constraint:** physical cards are Japanese and consistently DIFFERENT PRINTINGS than the English deck → feature-print is weak; the name + collector paths carry it.

**Old-frame / retro collision:** pre-M15 cards (Conspiracy, Mercadian Masques) print no set code, only `NN/total`; number-only reads collide across the all-printings table — Brainstorm (CNS 91/210), Counterspell (MMQ 69), solved by name + fusion. Retro frames (Crystal Shard TSR 393) print a *bare* number, no `/total` → the collector path can't read it at all; the name path carries them.

`Card.printedName` (JP, incl. DFC front face) is backfilled on launch via `SetupService.backfillPrintedNames` (schema default `""` → lightweight migration, no wipe). A scan also stamps `Card.lastScannedAt` for the History tab.

> **Don't trust specific thresholds/distances from memory — the pipeline is actively tuned. Read the source and the regression tests.**

Related: [[scanner_regression_tests]], [[device_debug_workflow]], [[data_driven_debugging]].
