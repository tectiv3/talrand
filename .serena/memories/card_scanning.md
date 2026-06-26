## How Talrand's Card Scanner Works (durable facts only)

The scanner (`CameraService` + `CameraScannerView`) recognizes a physical card via **two parallel paths per frame**:
1. **Feature-print** — `CardImageMatcher` / `VNGenerateImageFeaturePrint` on the card art vs deck reference images.
2. **Collector-code OCR** — bottom-strip text recognition → `CollectorNumberParser` → `CollectorNumberEntry` lookup (built from `fetchAllPrintings`, so it covers every printing).

**Hard constraint (this is the durable point):** the user's physical cards are Japanese and consistently DIFFERENT PRINTINGS than the English Moxfield-imported deck. Different printing → different art → feature-print is weak/fails. The **collector-code path is printing-agnostic and is the reliable path** for this deck. Swapping a deck entry to the owned printing makes feature-print work again (proven with An Offer → FDN#160).

**Open limitation:** old cards with no printed set code (e.g. Counterspell MMQ#69) can't be disambiguated when several deck cards share a collector number.

> **Do NOT trust any specific thresholds / distance values / vote-gate numbers from memory.** The scanner pipeline (thresholds, OCR, rectangle detection, camera service) is actively tuned — it changed substantially on 2026-06-26 across several commits. For current values and matching logic, read the source (`CameraService`, `CardImageMatcher`, `CollectorNumberParser`) and `SCANNING_NOTES.md` (repo root). Treat them as live, not memorized.

Related: `device_debug_workflow`, `data_driven_debugging`.
