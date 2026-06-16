# OCR Scanner Diagnostics & Accuracy Improvements

## Problem

When card scanning fails during swap, the error view shows only "Card not found" with no diagnostic information. The user cannot tell whether OCR misread the set code, the collector number, or if the card genuinely doesn't exist at that set/number. Additionally, Vision OCR has no hints about MTG set codes, so it may "correct" valid codes into dictionary words.

## Solution Overview

1. Thread raw OCR text and attempted lookup parameters through the scan → error chain
2. Tune Vision's `VNRecognizeTextRequest` with MTG-specific hints
3. Cache set codes from Scryfall `/sets` endpoint in UserDefaults
4. Add "Search by Name" fallback to the error view

## Component 1: Diagnostic Context Threading

### Data Flow

```
CameraService bundles ocrText WITH candidates in a wrapper struct
       ↓
CameraScannerView reads ocrText from the same struct (no race)
       ↓
onNewCardScanned callback passes ocrText alongside set/number
       ↓
CardSwapService.handleNewCardFromScan() receives ocrText parameter
       ↓
On error: composes rich message including set/number + OCR text
       ↓
CardSwapView.errorView renders multiline error
```

### Race Condition Fix

The current `recognizedCandidates` is set on main via `Task { @MainActor }`. A separate `lastOCRText` property would race — a new frame could overwrite it before `processCandidates` fires. Instead, introduce a wrapper:

```swift
struct ScanResult {
    let ocrText: String
    let candidates: [CollectorNumberCandidate]
}
```

`CameraService` publishes `var lastScanResult: ScanResult?` (set atomically on main thread alongside candidates). `CameraScannerView` observes `lastScanResult` instead of `recognizedCandidates`.

### File Changes

**CameraService.swift**
- Add `ScanResult` struct with `ocrText` + `candidates`
- Replace `var recognizedCandidates: [CollectorNumberCandidate]` with `var lastScanResult: ScanResult?`
- In `handleRecognitionResults()`: build ocrText, parse candidates, dispatch both together via `Task { @MainActor in self.lastScanResult = ScanResult(ocrText: ocrText, candidates: candidates) }`

**CameraScannerView.swift**
- Change `onChange(of: cameraService.recognizedCandidates)` to `onChange(of: cameraService.lastScanResult?.candidates)`
- `processCandidates` receives the full `ScanResult` so ocrText is synchronized with candidates
- Pass `ocrText` through the `onNewCardScanned` callback
- Only call site using `onNewCardScanned` is `CardSwapView` (`.swap` mode). `ContentView` uses `.lookup` mode and doesn't pass this callback — no breakage.

**CardSwapView.swift**
- Update `onNewCardScanned` closure to accept and forward `ocrText`
- Error view gets three actions: Try Again, Search by Name, Cancel
- "Search by Name" sets both `showingSearch = true` and `swapService.state = .scanning` in a single action to avoid flashing the camera view

**CardSwapService.swift**
- `handleNewCardFromScan()` accepts new `ocrText: String` parameter
- Catch block composes: `"Card not found: \(setCode.uppercased()) #\(collectorNumber)\nOCR read: «\(ocrText)»"`

## Component 2: Vision OCR Tuning

### Changes to VNRecognizeTextRequest in CameraService

1. `request.customWords = cachedSetCodes` — biases toward valid MTG set codes. Apple docs state custom words "supplement" the recognizer's dictionary. Effect may be modest for short alphanumeric codes, but it's zero-cost and can only help.
2. `request.usesLanguageCorrection = false` — prevents dictionary correction of alphanumeric codes. Safe because the scan region (bottom 25%) contains only collector info, not card names or rules text.
3. `request.minimumTextHeight = 0.02` — filters noise text in scan region. Conservative threshold to avoid filtering out small print on extended-art or foil layouts.

### Set Code Loading

- `CameraService` loads set codes from cache on `startSession()`
- Stored as `[String]` property, fed to each `VNRecognizeTextRequest`
- If cache empty/unavailable, `customWords` stays empty (no regression)

## Component 3: Set Code Cache

### Strategy: In-memory + UserDefaults

- Fetch `https://api.scryfall.com/sets` → extract `code` field from each set, uppercased
- Store in `UserDefaults` key `"cachedMTGSetCodes"` alongside timestamp key `"cachedMTGSetCodesDate"`
- On read: return cached if timestamp < 7 days old
- If stale or missing: fetch in background, update cache, return stale data (or empty) immediately
- Lives as a static method on `ScryfallAPI` or a small helper

### Scryfall /sets Response Model

Add a minimal `Codable` struct in `ScryfallAPI.swift`:

```swift
private struct ScryfallSetsResponse: Codable {
    let data: [ScryfallSetEntry]
}

private struct ScryfallSetEntry: Codable {
    let code: String
}
```

Fetch, extract codes, uppercase, collect into `[String]`. Scryfall currently has ~800 sets — this is a small array for both UserDefaults and `customWords`.

## Component 4: Error View UX

### Current

```
⚠️
Card not found
[Try Again]
Cancel
```

### New

```
⚠️
Card not found: CMM #124
OCR read: «CMM 124 EN»

[Try Again]
[Search by Name]
Cancel
```

- Primary error line: `.body` font
- OCR diagnostic line: `.caption` font, `.secondary` foreground, monospaced
- Omit OCR line if text is empty/nil
- "Search by Name" button transitions to the existing search view within CardSwapView
