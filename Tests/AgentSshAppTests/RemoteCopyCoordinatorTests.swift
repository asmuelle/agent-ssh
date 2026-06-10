@testable import AgentSshApp
import Foundation
import Testing

/// Pure-logic tests for the server→server relay copy: remote path
/// joining, relay temp file placement, the drag payload round-trip
/// the cross-pane drop depends on, and the Files grid column math.
@MainActor
struct RemoteCopyCoordinatorTests {
    // MARK: - Remote path joining

    @Test("Joins a directory and child name with a slash")
    func joinsNestedPath() {
        #expect(RemoteCopyCoordinator.joinRemotePath("/var/www", "site.tar") == "/var/www/site.tar")
    }

    @Test("Does not double the slash when the directory has a trailing slash")
    func joinTrailingSlash() {
        #expect(RemoteCopyCoordinator.joinRemotePath("/var/www/", "site.tar") == "/var/www/site.tar")
    }

    @Test("Session-root shorthand resolves to a bare name", arguments: [".", ""])
    func joinSessionRoot(dir: String) {
        #expect(RemoteCopyCoordinator.joinRemotePath(dir, "notes.txt") == "notes.txt")
    }

    @Test("Relative cwd joins like an absolute one")
    func joinRelativeCwd() {
        #expect(RemoteCopyCoordinator.joinRemotePath("projects/app", "config.yml") == "projects/app/config.yml")
    }

    // MARK: - Relay temp location

    @Test("Relay temp URL preserves the original filename")
    func relayTempPreservesName() {
        let url = RemoteCopyCoordinator.temporaryRelayURL(for: "backup.sql")
        #expect(url.lastPathComponent == "backup.sql")
    }

    @Test("Relay temp URLs are unique per call so concurrent copies of the same name cannot collide")
    func relayTempUnique() {
        let a = RemoteCopyCoordinator.temporaryRelayURL(for: "backup.sql")
        let b = RemoteCopyCoordinator.temporaryRelayURL(for: "backup.sql")
        #expect(a.path != b.path)
    }

    @Test("Relay temp URL lives under the app's relay scratch directory")
    func relayTempUnderScratchDir() {
        let url = RemoteCopyCoordinator.temporaryRelayURL(for: "x")
        #expect(url.path.contains("agent-ssh-relay"))
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    // MARK: - Drag payload round-trip

    @Test("RemoteFileDrag survives the pasteboard encode/decode round trip")
    func dragRoundTrip() throws {
        let drag = RemoteFileDrag(
            connectionId: "conn-a",
            remotePath: "/srv/data/dump.tar.gz",
            name: "dump.tar.gz",
            size: 123_456,
            kind: .file
        )
        let encoded = try #require(drag.pasteboardString)
        let decoded = try #require(RemoteFileDrag.decodePasteboardString(encoded))

        #expect(decoded.connectionId == "conn-a")
        #expect(decoded.remotePath == "/srv/data/dump.tar.gz")
        #expect(decoded.name == "dump.tar.gz")
        #expect(decoded.size == 123_456)
        #expect(decoded.kind == .file)
    }

    @Test("Arbitrary dropped text is rejected, not decoded into a copy")
    func dragRejectsGarbage() {
        #expect(RemoteFileDrag.decodePasteboardString("hello world") == nil)
        #expect(RemoteFileDrag.decodePasteboardString("rshell-remote-file:not-base64!!") == nil)
    }

    // MARK: - Files grid columns

    @Test(
        "Grid column count scales with the number of connected hosts",
        arguments: [
            (panes: 1, columns: 1),
            (panes: 2, columns: 2),
            (panes: 3, columns: 2),
            (panes: 4, columns: 2),
            (panes: 5, columns: 3),
            (panes: 9, columns: 3),
        ]
    )
    func gridColumns(panes: Int, columns: Int) {
        #expect(FilesPanel.columnCount(forPaneCount: panes) == columns)
    }
}
