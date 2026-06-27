# Close-range camera tuning for OCR — design

## Problem

Talrand OCRs small, low-contrast Japanese **collector numbers** from physical cards held
close to the camera. The wide camera's minimum-focus dead zone blurs close-held subjects,
and the only thing currently producing macro focus is opaque, driver-controlled
ultra-wide constituent switching — non-deterministic, latent, and absent on some phones.
On the iPhone 14 Pro (`soPro`, the debug device) the wide-cam dead zone is ~20cm, the
worst case, so "hold it closer" backfires and OCR silently fails.

`CameraService.preferredCamera()` today picks the first available virtual device and sets
**no** focus, zoom, or AF-range APIs. Macro focus is a pure side effect.

Research notes: `docs/camera-scanning-improvements.md`.

## Goal

Apply the WWDC21 `AVCamBarcode` technique — compute a `videoZoomFactor` from
`minimumFocusDistance` so the sharp distance lands just outside the dead zone, giving more
pixels on the collector strip — and make it **runtime-toggleable** so the zoom arm can be
A/B-compared against driver auto-macro on-device against real OCR results before committing.

Non-goal: expanding camera behavior beyond what serves collector-number OCR. Personal-use
app; mid-game speed and offline reliability are the priorities.

## Outcome (2026-06-27, on-device measurement)

**The zoom was a confirmed negative and was reverted; only the always-on AF hints shipped.**
On-device diagnostics (iPhone 14 Pro, `soPro`) at `videoZoomFactor=1.0`:

```
minFocus=20  fov=106.2  range=[1.0, 123.75]  applied=1.0  (already focusable)
```

`minimumFocusDistance` reported **20 mm** (not the ~200 mm the research doc assumed) and
`fov=106°` — i.e. the `builtInTripleCamera` serves the **ultra-wide** constituent at 1.0×,
which already focuses to ~2 cm. The WWDC21 formula therefore correctly computes *no zoom*
(desired framing distance ≈79 mm is outside the 20 mm dead zone), so ON and OFF produced
**identical 1.0× captures**; scans were fast and indistinguishable in both arms. The
technique solves a large-dead-zone problem this device does not have.

Reverted: `CloseRangeZoom`, the `videoZoomFactor` logic, and the `closeRangeZoom` toggle.
Kept: `configureForCloseRange` reduced to the AF hints (`continuousAutoFocus` + `.near`),
a strict, free improvement so AF stops hunting toward infinity on close cards.

The remaining OCR lever, if collector-number recognition ever proves weak, is **pixel
density** — forcing a zoom onto the wide/tele constituent for more pixels on the strip —
not the dead-zone formula. Deferred until a real OCR-failure case justifies it.

## Decisions (settled during brainstorming)

- **Strategy: both, runtime-toggleable.** Implement the zoom but gate it behind a debug
  toggle so zoom vs. auto-macro can be measured on-device. Data decides.
- **Toggle scope: zoom only; AF hints always on.** AF hints (`continuousAutoFocus` +
  `autoFocusRangeRestriction = .near`) are strictly beneficial and the research doc
  recommends them even with auto-macro. Gating only the zoom isolates the single variable
  under test.
- **No unit test for the zoom math.** The formula body is tautological to test
  (a test re-encodes the same arithmetic). The real uncertainty is the tuning constants
  and whether the zoom improves OCR — empirical, on-device only. The two genuine
  boundaries (`minFocus <= 0`, clamp to `maxZoom`) are surfaced by the debug `print()`.

## A/B arms this produces

| Toggle | Behavior |
|--------|----------|
| OFF (default) | AF hints + driver auto-macro |
| ON | AF hints + deterministic computed zoom; auto-macro suppressed by `videoZoomFactor > 1` |

**Important — neither arm is today's pristine behavior.** Today's code sets *no* focus,
AF-range, or zoom APIs. Both arms here apply the always-on AF hints
(`continuousAutoFocus` + `autoFocusRangeRestriction = .near`), which today's code does not.
So OFF = "today + AF hints," not "today." This is intentional: the experiment isolates the
**marginal effect of the zoom** given AF hints, which is exactly the variable under test.
If a true untouched baseline is ever needed it would be a third state (skip
`configureForCloseRange` entirely) — out of scope (YAGNI).

Default OFF is the conservative arm; you opt in to test the zoom.

## Components

### 1. `CloseRangeZoom` — pure seam (new)

A small AVFoundation-free type holding the zoom math and its tuning constants as the single
source of truth, so on-device tuning is a one-line edit + rebuild. Mirrors the codebase's
existing testable-seam convention (`ScanOCR`, `DeckResolver`).

```swift
enum CloseRangeZoom {
    /// Physical width (mm) of the target region we want framed.
    /// MTG card width = 63mm. The whole card (NOT just the ~15mm collector strip)
    /// must stay in frame: ScanOCR.detectCard does rectangle+perspective detection on
    /// the full card and name OCR reads the top title bar. Zooming to the strip would
    /// crop the card out and break both. Tune on-device, but stay card-scaled.
    static let targetWidthMM: Float = 63
    /// Fraction of the frame width the card should occupy. Conservative starting prior:
    /// leaves margin so the portrait card (88mm tall) also fits the vertical FOV and the
    /// rectangle detector keeps a clean border. Tune on-device.
    static let fillFraction: Float = 0.6

    /// Returns the desired (unclamped) zoom factor, or nil when no zoom is warranted
    /// (minFocus unavailable, or subject already focusable without zoom).
    /// Clamping to the device's [minAvailable, maxAvailable] range is the caller's job,
    /// since those bounds live on the AVCaptureDevice.
    static func factor(minFocusMM: Float, fovDegrees: Float) -> CGFloat?
}
```

Logic (WWDC21):
- `guard minFocusMM > 0 else { return nil }` — `minimumFocusDistance` is `-1` when
  unavailable.
- `filled = targetWidthMM / fillFraction`
- `minSubjectDistance = filled / tan(fovDegrees/2 · π/180)` — `fovDegrees` is
  `activeFormat.videoFieldOfView`, the immutable full-frame (zoom=1.0) **horizontal** FOV;
  it does not change with `videoZoomFactor`, so the formula is self-consistent regardless
  of any zoom already applied from a prior session.
- `guard minSubjectDistance < minFocusMM else { return nil }` — already focusable; no zoom.
- `zoom = minFocusMM / minSubjectDistance` (unclamped; caller clamps).

No unit test (see Decisions). Kept pure purely for clarity — separates arithmetic from
AVFoundation glue and makes the formula eyeball-able.

### 2. `CameraService.configureForCloseRange(_ device:)` (new private method)

Runs on `processingQueue`. `lockForConfiguration` / `defer unlock`.

**Crash-safety note:** setting an unsupported `focusMode`/`autoFocusRangeRestriction`, or a
`videoZoomFactor` outside `[minAvailableVideoZoomFactor, maxAvailableVideoZoomFactor]`,
throws an Objective-C `NSInvalidArgumentException` — **not** a catchable Swift error. Every
set below is therefore guarded.

- **Always**, each guarded by its explicit support check:
  - `if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }`
  - `if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }`
    (only takes effect while autofocusing, which the line above ensures).
- **Zoom**, clamped to the device's available range on both ends:
  - Let `lo = device.minAvailableVideoZoomFactor`, `hi = device.maxAvailableVideoZoomFactor`.
    On a virtual device `lo` can be `> 1.0` (e.g. when the OS has hidden the ultra-wide
    constituent), so `1.0` is **not** a safe literal to write.
  - **If `UserDefaults.standard.bool(forKey: "closeRangeZoom")`**:
    `desired = CloseRangeZoom.factor(minFocusMM: device.minimumFocusDistance, fovDegrees: device.activeFormat.videoFieldOfView)`;
    `device.videoZoomFactor = desired.map { min(max($0, lo), hi) } ?? max(1.0, lo)`.
  - **Else**: `device.videoZoomFactor = max(1.0, lo)` — crash-safe reset so toggling back
    off restores the (near-)default zoom and lets auto-macro re-engage.
- When `UserDefaults.standard.bool(forKey: "scannerDebug")`: `print()` minFocus, FOV, the
  available `[lo, hi]` range, and the applied zoom — and when `factor` returned `nil`,
  print **which** reason (minFocus unavailable vs. already focusable) so the most
  interesting case (why zoom did NOT apply) is diagnosable. Visible via the
  `devicectl --console` workflow; this is the data-driven A/B loop.

### 3. Call site — `startSession()`

`setupSession()` is guarded by `isConfigured` and runs once per app launch, so device
config must be re-applied on each session start to pick up the live toggle. Invoke
`configureForCloseRange(activeDevice)` inside the existing `processingQueue.async` block in
`startSession()`, **after `captureSession.startRunning()`** — matching the `toggleTorch`/
`stopSession` precedent of locking the device only once the session is established, and
avoiding configuring a device the running session hasn't yet taken active.

**Lifecycle (verified):** `CameraScannerView` calls `startSession()` in `onAppear` and
`stopSession()` in `onDisappear`; `startSession()`'s `processingQueue` block is *not*
`isConfigured`-guarded (only `setupSession()` is), so it runs on every reopen. Therefore
flipping the gear-menu toggle and reopening the scanner re-applies config with no relaunch.
`stopSession()` sets `isRunning = false`, clearing the `guard !isRunning` at the top of
`startSession()` so the reopen path runs.

### 4. UI — DeckListView Debug section

Add beside the existing "Scanner diagnostics" toggle:

```swift
@AppStorage("closeRangeZoom") private var closeRangeZoom = false
// ...
Toggle("Close-range zoom", isOn: $closeRangeZoom)
```

Matches the established `@AppStorage("scannerDebug")` → `UserDefaults` read pattern.

## Out of scope (YAGNI)

Deferred "low-cost wins" from the research doc, revisit only if OCR is still weak after
measuring this: user-facing tuning sliders, higher-resolution `activeFormat` selection,
`rectOfInterest` region crop, tap-to-focus / periodic AF retrigger.

## Verification

On-device only (camera can't run in simulator; see `device_debug_workflow`). With
`scannerDebug` on, launch via `devicectl --console`, scan a Japanese card under each toggle
state, and compare the printed zoom/minFocus/range values and collector-strip legibility
(`Documents/scan_strip.jpg` dump). `make build` is the authoritative typecheck.

Two assumptions can only be confirmed on the device, not in the sim — check them in the
first session before trusting the A/B:
- **That `videoZoomFactor > 1` actually suppresses auto-macro** on the iPhone 14 Pro
  `builtInTripleCamera`. If it doesn't, the two arms aren't cleanly separated. Confirm the
  preview visibly stops lens-switching when ON.
- **That `sessionPreset = .high` selects a format whose FOV/resolution makes the computed
  zoom sensible** — read the printed FOV and applied zoom and sanity-check the card stays
  fully framed and sharp at arm's length.
