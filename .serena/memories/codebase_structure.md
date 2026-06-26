## Codebase Structure

Root:
- `project.yml` — XcodeGen spec (source of truth for the Xcode project)
- `Makefile` — `make build`, `make generate`
- `README.md`, `LICENSE`, `SCANNING_NOTES.md` (full scanner writeup)
- `docs/superpowers/specs/` — design specs
- `Talrand.xcodeproj` — GENERATED, do not hand-edit

`Talrand/`:
- `TalrandApp.swift` — `@main`, SwiftData `modelContainer` registration
- `ContentView.swift` — root view
- `Info.plist`
- `Models/` — `Card`, `Deck`, `DeckEntry`, `CollectorNumberEntry`, `Ruling` (SwiftData `@Model`)
- `Services/` —
  - `CameraService` — capture + per-frame two-path recognition
  - `CardImageMatcher` — `VNGenerateImageFeaturePrint` art matching
  - `CollectorNumberParser` — OCR collector-code parsing
  - `ScryfallAPI` — card data / printings / rulings
  - `DeckLoader`, `SetupService`, `CardSwapService`, `ImageCacheService`
- `Views/` — `CameraScannerView`, `CardDetailView`, `CardPagerView`, `CardSwapView`, `CardThumbnail`, `DeckListView`, `SetupView`, `MTGTheme`, `ManaCostView`, `ManaSymbolLegend`
- `Resources/deck.json` — bundled deck data

See `card_scanning` memory for how the scanner pipeline works.
