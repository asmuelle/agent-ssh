# agent-ssh Copilot Instructions

## Build commands
- Rust check: `just check` (cargo check --all-targets)
- Lint: `just lint` (cargo fmt --check + clippy -D warnings)
- Rust tests: `just test-rust`
- Swift tests: `just mac-test`
- Full macOS build: `just mac-build`
- Debug build: `just mac-build-dev`
- Run debug app: `just mac-run-dev`

## Architecture
- macOS UI: `AgentSshApp/` (SwiftUI + AppKit)
- iPadOS UI: `AgentSshMobile/`
- Shared framework: `Sources/AgentSshMacOS/`
- Rust FFI surface: `src/ffi.rs` (uniffi exports)
- Generated bindings: `bindings/midnight_ssh.swift` — never hand-edit
- Xcode project: generated from `project.yml` via xcodegen

## Critical conventions
- `BridgeManager` is the single FFI entry point; extensions use `BridgeManager+<Feature>.swift`
- `@MainActor` on all UI-mutating Swift code
- After changes to `src/ffi.rs`: run `just mac-bindings` and commit generated bindings
- FFI error returns: `Result<T, String>` at the boundary
- Network calls in FFI: `RUNTIME.block_on(async { … })` pattern
- Never edit `.xcodeproj` directly — edit `project.yml` and run `just mac-gen`
