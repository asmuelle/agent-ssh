// swift-tools-version: 5.9
// agent-ssh SPM package — pure-Swift models shared by the native macOS app.
//
// ## Prerequisites
//
//   brew install xcodegen
//
// ## Setup (one-time)
//
//   1. Generate Xcode project:
//        cd agent-ssh && xcodegen generate
//
//   2. Open Mc-Ssh.xcodeproj in Xcode
//
//   3. Select the AgentSshApp scheme, choose and macOS target, run
//
// The Xcode app target links the Rust static library directly. This SwiftPM
// package intentionally stays pure Swift so `swift test` can run without a
// prebuilt Cargo artifact or custom library search paths.
//
// ## Generating Swift bindings
//
// After every FFI change run `just mac-bindings`, which is equivalent to:
//
//   cargo build --release --lib
//   uniffi-bindgen generate \
//     --library target/release/libagent_ssh.dylib \
//     --language swift \
//     --out-dir bindings
//
// followed by renaming `agent_sshFFI.modulemap` to `module.modulemap` so
// Swift auto-discovers it along SWIFT_INCLUDE_PATHS.

import PackageDescription

let package = Package(
    name: "agent-ssh",
    platforms: [
        .macOS(.v13),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "AgentSshMacOS",
            targets: ["AgentSshMacOS"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AgentSshMacOS",
            path: "Sources/AgentSshMacOS"
        ),
        .testTarget(
            name: "AgentSshMacOSTests",
            dependencies: ["AgentSshMacOS"],
            path: "Tests/AgentSshMacOSTests"
        ),
    ]
)
