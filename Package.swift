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
// After every FFI change:
//
//   cargo build -p agent-ssh --release --target aarch64-apple-darwin
//   uniffi-bindgen generate \
//     target/aarch64-apple-darwin/release/libmidnight_ssh.dylib \
//     --language swift \
//     --out-dir bindings
//
// Then add the generated `midnight_sshFFI.h` and `midnight_sshFFI.modulemap`
// to the Xcode project's "Swift Compiler — General" > "Import Paths".

import PackageDescription

let package = Package(
    name: "agent-ssh",
    platforms: [
        .macOS(.v11),
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
