import Foundation
import XCTest

final class SharedJSONFileStoreIsolationTests: XCTestCase {
    func testSharedJSONFileStoreCompilesWithoutFeatureSpecificSources() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryURL
            .appendingPathComponent("Sources/AgentSshMacOS/SharedJSONFileStore.swift")
        let moduleCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ssh-shared-json-test-(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: moduleCacheURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: moduleCacheURL) }

        let process = Process()
        let diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-module-cache-path", moduleCacheURL.path,
            sourceURL.path,
        ]
        process.standardOutput = diagnostics
        process.standardError = diagnostics

        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "SharedJSONFileStore must remain independently compilable for widget and extension targets.\n\(output)"
        )
    }
}
