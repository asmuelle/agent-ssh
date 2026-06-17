# Contributing to agent-ssh

Thanks for taking the time to look at the internals. This is a native
macOS / iPadOS SSH workspace with a Rust protocol core bridged to Swift via
[UniFFI](https://mozilla.github.io/uniffi-rs/). Contributions of all sizes are
welcome — bug reports, focused fixes, and well-scoped features.

## License & CLA

- The project is licensed under **[AGPL-3.0](LICENSE)**. By contributing, you
  agree your Contributions are licensed under the same terms.
- Because the project is also offered under separate commercial terms, all
  contributors must agree to the **[Contributor License Agreement](CLA.md)**.
  Add the one-line acknowledgement from the CLA to your first pull request.

## Getting set up

**Prerequisites** (see [README.md](README.md) for detail):

- macOS 14+ with Xcode 15+ and command-line tools
- Rust **1.95+** (edition 2024) — `rustup default stable`
- [`just`](https://github.com/casey/just) — `brew install just`
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

```bash
just bootstrap          # one-time: xcodegen + macOS + iOS Rust targets
just mac-build          # native macOS app (ad-hoc signed)
just mac-run
```

Run `just` with no arguments for the full recipe list.

## Local checks (run before you open a PR)

| Command | What it does |
|---------|--------------|
| `just check` | Fast Rust compile check (`cargo check --all-targets`) |
| `just lint` | Format + clippy — **CI gate, must pass** |
| `just test-rust` | Rust unit/integration tests |
| `just mac-test` | Swift framework + FFI integration tests |
| `just ci-local` | Full local CI pass |

A PR is ready for review when `just lint` and the relevant test recipe pass
locally and CI is green.

## Changing the Rust ↔ Swift FFI

The Swift bindings under `bindings/` are **generated and committed**. Never
hand-edit `bindings/midnight_ssh.swift` — the per-function UniFFI checksums will
diverge from the Rust library and `rshellInit()` will crash at launch.

```bash
# 1. Edit src/ffi.rs (or src/lib.rs) and export with #[uniffi::export]
# 2. Regenerate bindings
just mac-bindings
# 3. Rebuild and commit the regenerated bindings together with your Rust change
just mac-build
```

## Code conventions

**Rust**

- FFI boundary returns `Result<T, String>` (converted from `anyhow::Result<T>`).
- Network calls run on the shared runtime: `RUNTIME.block_on(async { … })`.
- `PascalCase` types, `snake_case` functions.

**Swift**

- `BridgeManager` is the single FFI entry point; feature extensions live in
  `BridgeManager+<Feature>.swift`.
- `@MainActor` on UI-mutating code; move work off-main with `Task` /
  `DispatchQueue.global()`.
- State types are named `*Store` / `*Manager`.

See [AGENTS.md](AGENTS.md) for the full architecture tour and [TOOLS.md](TOOLS.md)
for the feature catalog and where each surface lives.

## Commits & pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`, `ci:`.
- Keep PRs focused — one logical change per PR is easiest to review.
- Describe the *why*, not just the *what*, and include a short test plan.
- Link any related issue.

## Reporting bugs & proposing features

Open an issue with:

- What you expected vs. what happened, and steps to reproduce.
- Your macOS / iPadOS and Xcode versions, and `rustc --version`.
- For crashes at `rshellInit()`, confirm bindings were regenerated via
  `just mac-bindings` (a common cause is a stale hand-edited binding).

By participating you agree to keep interactions respectful and constructive.
