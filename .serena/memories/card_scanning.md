## How Talrand's Card Scanner Works (durable facts only)

The scanner (`CameraService` + `CameraScannerView`) recognizes a physical card per frame via **four signals**, in priority order:
1. **Name** — `recognizeCardName` OCRs the top title bar (ja+en) → `CardNameMatcher` matches against the deck's English names AND Japanese printed names (`Card.printedName`, backfilled from Scryfall). A unique 2-frame match fires directly. **This is the strategic, most reliable path for the user's Japanese cards** — printing-independent and collision-free.
2. **Feature-print** — `CardImageMatcher` / `VNGenerateImageFeaturePrint` on the card art vs deck reference images. Strong+clear match fires; its nearest neighbour is also exposed (`nearestMatchId`) even when too weak to fire, for fusion.
3. **Collector-code OCR** — bottom strip → `CollectorNumberParser` → `CollectorNumberEntry` lookup (built from `fetchAllPrintings`, covers every printing).
4. **Fusion** — when a collector number maps to several deck cards, `findCard` picks the one equal to feature-print's `nearestMatchId` (constrained to the candidate set → safe), else uses OCR'd type, else refuses.

**Hard constraint (the durable point):** the user's physical cards are Japanese and consistently DIFFERENT PRINTINGS than the English Moxfield deck. Different printing → different art → feature-print is weak. The name + collector-code/fusion paths are printing-agnostic and carry the deck.

**Old-frame collision problem:** pre-M15 cards (Conspiracy, Mercadian Masques) print NO set-code text, only `NN/total`. Number-only reads collide across the all-printings table. Brainstorm (physical CNS 91/210, deck 13/90) and Counterspell (physical MMQ#69) are the canonical cases — addressed by the name path + fusion.

`Card.printedName` (JP) is backfilled on launch via `SetupService.backfillPrintedNames` (schema default `""` → no store wipe; only cards missing a name hit the network).

> **Do NOT trust specific thresholds/distances from memory.** The pipeline is actively tuned. Read the source (`CameraService`, `CardImageMatcher`, `CollectorNumberParser`/`CardNameMatcher`) and `SCANNING_NOTES.md` for live values.

Related: `device_debug_workflow`, `data_driven_debugging`.
