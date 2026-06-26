## Physical-device debug workflow (camera can't run in simulator)

- Device name: **`soPro`** (iPhone 14 Pro). App bundle id: **`com.talrand.app`**.
- The Mac CANNOT pull iOS unified logs directly, but `devicectl` can launch the app attached to its console, forwarding Swift `print()` (stdout):
  ```
  xcrun devicectl device process launch --device soPro --console --terminate-existing com.talrand.app
  ```
  Run it backgrounded, redirect to a file, read that file. The user must rebuild/install from Xcode first (and stop the Xcode run) so the latest build is what launches.
- Pull a file the app wrote to its Documents container (e.g. debug image dumps):
  ```
  xcrun devicectl device copy from --device soPro --domain-type appDataContainer --domain-identifier com.talrand.app --source Documents/scan_strip.jpg --destination <localpath>
  ```
  Then Read the JPG to inspect the OCR crop quality / collector-code legibility visually.
- `make build` is the authoritative typecheck (iOS Simulator target). SourceKit editor diagnostics (`No such module 'UIKit'`, `Cannot find type 'Card'`) are macOS-index noise.

Related: `card_scanning`.
