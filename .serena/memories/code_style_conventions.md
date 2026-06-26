## Code Style & Conventions

- **Swift 5.9 / SwiftUI** idioms. Standard Swift naming: `UpperCamelCase` types, `lowerCamelCase` members.
- **Layout:** feature-grouped folders — `Models/`, `Services/`, `Views/`, `Resources/`. New files must be added under `Talrand/` and the project regenerated with `make generate` (XcodeGen picks up sources by directory).
- **SwiftData `@Model`:** ALWAYS set a default value on stored properties (e.g. `var board: String = "mainboard"`). Without defaults, SwiftData cannot do lightweight migration and silently wipes the store. See `swiftdata_defaults` memory.
- **Comments:** only explain *why*, not *what*, and only when necessary (per user global guidelines).
- **No new dependencies / API abstractions:** prefer existing patterns. Network access goes through the service layer (e.g. `ScryfallAPI`), not ad-hoc fetch calls scattered in views.
- **Centralize:** single source of truth; avoid hardcoding the same value in multiple places.
- **Do not assume requirements.** When multiple approaches exist, ask the user before implementing.
