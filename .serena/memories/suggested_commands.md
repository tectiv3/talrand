## Suggested Commands (Talrand, macOS/Darwin)

### Build / typecheck (authoritative)
```
make build
```
Builds for the iOS Simulator (iPhone 17 Pro destination) with sandbox-disabling flags. This is the **authoritative typecheck** — SourceKit / editor diagnostics like `No such module 'UIKit'` or `Cannot find type 'Card'` are macOS-index noise and can be ignored; `make build` is what counts. `node` cannot check `.vue`/Swift files.

### Regenerate Xcode project (after adding/removing files or editing project.yml)
```
make generate
```

### Formatting
Use the **global `prettier`** command directly (not via npx) where applicable. (No Swift formatter configured in repo.)

### On-device debugging (camera can't run in simulator)
Physical device name **`soPro`** (iPhone 14 Pro). See the `device_debug_workflow` memory for `devicectl` launch/console and file-pull commands.

### Git / util (Darwin BSD userland)
Standard `git`, `ls`, `grep`, `find` — note BSD variants differ from GNU (e.g. `sed -i ''`, no `-P` in grep by default). Prefer ripgrep/serena search tools.

### Nix tooling
Prefer `nix shell nixpkgs#<pkg> -c <cmd>` for ad-hoc tools; xcodegen is invoked via nix in the Makefile.
