## SwiftData: always default new @Model properties

When adding a new stored property to a SwiftData `@Model` class, ALWAYS include a default value on the property declaration (e.g. `var board: String = "mainboard"`) — not just on the `init` parameter. Without it, SwiftData cannot perform lightweight migration and **silently destroys/recreates the store on every launch, wiping all user data**.

**Why:** this bug caused a full re-download of 68 cards from the rate-limited Scryfall API on every launch, because `var board: String` had no default.

**Verify:** after any schema change, confirm the app retains data across launches.
