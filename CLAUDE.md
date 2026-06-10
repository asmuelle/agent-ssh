# CLAUDE.md — agent-ssh quickstart

## Build & verify
- `just check` — fast Rust compile check (`cargo check --all-targets`)
- `just lint` — format + clippy (CI gate, must pass)
- `just test-rust` — Rust tests
- `just mac-test` — Swift framework + FFI integration tests
- `just mac-build` — signed release .app
- `just mac-build-dev` — debug .app (with development signing for widgets)
- `just mac-run-dev` — build + launch debug .app with widgets

## Project architecture
- macOS UI: `AgentSshApp/` — SwiftUI views, AppKit shell
- iPadOS UI: `AgentSshMobile/`
- Shared framework: `Sources/AgentSshMacOS/` — models, stores, helpers
- Rust FFI surface: `src/ffi.rs` (uniffi exports), `src/bridge.rs` (tokio runtime)
- Generated bindings: `bindings/midnight_ssh.swift` — **never hand-edit**
- Xcode project: generated from `project.yml` via `xcodegen` (`.xcodeproj` is gitignored)

## FFI workflow
1. Add/change fn in `src/ffi.rs` with `#[uniffi::export]`
2. `just mac-bindings` — regenerates `bindings/`
3. Commit the regenerated bindings

## Swift conventions
- `BridgeManager` is the single FFI entry point; extensions: `BridgeManager+<Feature>.swift`
- `@MainActor` on UI-mutating code; off-main = `Task` / `DispatchQueue.global()`
- State classes: `*Store` / `*Manager`

## Rust conventions
- FFI boundary: `Result<T, String>` for errors (converted from `anyhow::Result<T>`)
- Network calls: `RUNTIME.block_on(async { … })` — pattern in `src/ffi.rs`
- `PascalCase` types, `snake_case` functions

## Common pitfalls
- Never hand-edit `bindings/midnight_ssh.swift` — FFI checksum mismatch = crash at `rshellInit()`
- Stale SPM cache → `rm -rf build .build && just mac-gen && just mac-build`
- See AGENTS.md for full architecture, TOOLS.md for feature catalog
