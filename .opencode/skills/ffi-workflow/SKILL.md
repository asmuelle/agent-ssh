---
name: ffi-workflow
description: Add or change a Rust FFI function, regenerate Swift bindings, and commit
---

## When to use me
Use this skill whenever you need to:
- Add a new `#[uniffi::export]` function to `src/ffi.rs`
- Change an existing FFI function signature
- Fix a binding mismatch issue

## Workflow

1. Edit `src/ffi.rs` — add or change `#[uniffi::export]` functions
2. Run `just check` to verify Rust compiles
3. Run `just mac-bindings` to regenerate `bindings/midnight_ssh.swift`
4. Commit both `src/ffi.rs` and the regenerated `bindings/` files

## Key rules

- Return types at FFI boundary: `Result<T, String>` for errors (converted from `anyhow::Result<T>`)
  - Use existing custom error types from `src/ffi.rs` when a category already exists (e.g., `FfiPgError`)
  - Fall back to `Result<T, String>` for new error categories
- Any network call: wrap in `RUNTIME.block_on(async { … })` — see existing patterns
- Types: `PascalCase`, functions: `snake_case`
- Every new FFI type must derive `uniffi::Enum` or `uniffi::Record` as appropriate

## Verification

After running `just mac-bindings`:
- Confirm `bindings/midnight_ssh.swift` contains the new type/function
- Build: `just mac-build` (or `just mac-ci-build` for CI)
- Test: `just mac-test`

## Pitfalls

- **Never hand-edit** `bindings/midnight_ssh.swift` — uniffi bakes a per-function checksum into both lib and bindings. Mismatch = `_assertionFailure` at `rshellInit()`.
- If the build fails with `use of undeclared type`, the bindings are out of sync — re-run `just mac-bindings`.
- If `just mac-bindings` fails, check that `cargo build --release --lib` succeeds first.
