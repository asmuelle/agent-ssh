---
description: Add a new FFI function to the Rust bridge and regenerate bindings
agent: build
---
I need to add a new FFI function to the Rust bridge. Follow the existing patterns:

1. Add the function to `src/ffi.rs` with `#[uniffi::export]` and `fn rshell_<name>(...) -> Result<T, String>`
2. For network operations, use `RUNTIME.block_on(async { … })` — follow existing patterns in the file
3. Use `PascalCase` for types, `snake_case` for functions
4. After implementing, remind me to run `just mac-bindings` and commit the generated bindings
