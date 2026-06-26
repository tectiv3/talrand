## When a Task Is Complete

1. **If files were added/removed/renamed:** run `make generate` (XcodeGen) so the Xcode project includes them.
2. **Typecheck / build:** run `make build`. This is the authoritative check — ignore SourceKit editor-only errors (`No such module 'UIKit'`, `Cannot find type 'Card'`).
3. **SwiftData schema changes:** verify every new `@Model` stored property has a default value, and confirm the app retains data across launches (no silent store reset).
4. **Camera / scanning changes:** can only be verified on the physical device `soPro` (not simulator). Bundle several changes per device rebuild — each on-device test costs a manual Xcode rebuild. Gather logs/cropped images via `devicectl` (see `device_debug_workflow`).
5. **Before finalizing scanner work:** strip any debug instrumentation (verbose flags, debug-image dumps, `[scan]`/`[match]`-style prints) — grep the scanner sources, since exact symbol names change as the pipeline is refactored.
6. **Never push to remote** (`git push`, `gh pr create`) unless explicitly told to.
