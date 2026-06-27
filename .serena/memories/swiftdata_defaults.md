## SwiftData: always default new @Model properties

When adding a new stored property to a SwiftData `@Model` class, ALWAYS include a default value on the property declaration (e.g. `var board: String = "mainboard"`) — not just on the `init` parameter. Without it, lightweight migration can fail.

**Verify:** after any schema change, confirm the app retains data across launches.

**Note (corrected 2026-06-27):** the "68 cards re-download on every launch" setup-loop
incident was NOT caused by a missing property default. Its real cause was the iCloud
entitlement forcing a CloudKit-backed store that failed to load and fell back to
in-memory — see [[swiftdata_cloudkit_inmemory_fallback]]. Keep this rule as general
SwiftData hygiene, but don't attribute that specific incident to it.
