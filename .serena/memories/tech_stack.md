## Tech Stack

- **Language:** Swift 5.9
- **UI:** SwiftUI
- **Persistence:** SwiftData (`@Model`) — model container in `TalrandApp.swift` registers `Card`, `Deck`, `DeckEntry`, `CollectorNumberEntry`, `Ruling`
- **Vision/OCR:** Vision framework — `VNGenerateImageFeaturePrint` (neural card-art fingerprints) + text recognition for collector numbers
- **Camera:** AVFoundation
- **API:** Scryfall public API (card data, images, rulings, printings) — no API key
- **Targets:** iOS 17+, Xcode 16+, iPhone only (TARGETED_DEVICE_FAMILY = 1), portrait only

## Project generation

- Xcode project is generated from `project.yml` via **XcodeGen** (do NOT hand-edit `Talrand.xcodeproj`).
- `make generate` regenerates the project (`nix shell nixpkgs#xcodegen -c xcodegen generate`).
