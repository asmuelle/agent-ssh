import XCTest
@testable import AgentSshMacOS

final class SSHConfigParserTests: XCTestCase {
    // MARK: - Basic stanzas

    func testParsesSimpleHostBlock() {
        let config = """
        Host web1
            HostName web1.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries, [SSHConfigHostEntry(
            alias: "web1",
            hostName: "web1.example.com",
            user: "deploy",
            port: 2222,
            identityFile: "~/.ssh/id_ed25519"
        )])
    }

    func testMultipleHostsPreserveFileOrder() {
        let config = """
        Host beta
            HostName beta.example.com
        Host alpha
            HostName alpha.example.com
        """

        XCTAssertEqual(SSHConfigParser.parse(config).map(\.alias), ["beta", "alpha"])
    }

    func testHostLineWithMultipleAliases() {
        let config = """
        Host web1 web2
            User deploy
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries.map(\.alias), ["web1", "web2"])
        XCTAssertEqual(entries.map(\.user), ["deploy", "deploy"])
    }

    func testMissingOptionsStayNil() {
        let entries = SSHConfigParser.parse("Host bare\n")

        XCTAssertEqual(entries, [SSHConfigHostEntry(alias: "bare")])
    }

    // MARK: - Resolution semantics (first obtained wins)

    func testEarlierWildcardDefaultsWinOverLaterStanzas() {
        // ssh_config(5): the first obtained value is used, so leading
        // defaults override later per-host values.
        let config = """
        Host *
            User admin
        Host web1
            User deploy
            HostName web1.example.com
        """

        let entry = SSHConfigParser.parse(config).first

        XCTAssertEqual(entry?.user, "admin")
        XCTAssertEqual(entry?.hostName, "web1.example.com")
    }

    func testTrailingWildcardDefaultsFillGaps() {
        let config = """
        Host web1
            HostName web1.example.com
        Host *
            User fallback
            Port 2200
        """

        let entry = SSHConfigParser.parse(config).first

        XCTAssertEqual(entry?.user, "fallback")
        XCTAssertEqual(entry?.port, 2200)
    }

    func testOptionsBeforeAnyHostApplyGlobally() {
        let config = """
        User global
        Host web1
            HostName web1.example.com
        """

        XCTAssertEqual(SSHConfigParser.parse(config).first?.user, "global")
    }

    func testPatternStanzaContributesButIsNotImported() {
        let config = """
        Host *.internal
            User ops
        Host db1.internal
            Port 5432
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries.map(\.alias), ["db1.internal"])
        XCTAssertEqual(entries.first?.user, "ops")
        XCTAssertEqual(entries.first?.port, 5432)
    }

    func testNegatedPatternExcludesStanza() {
        let config = """
        Host * !bastion
            Port 2222
        Host bastion
            HostName bastion.example.com
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries.first?.port)
    }

    func testDuplicateAliasStanzasMergeFirstWins() {
        let config = """
        Host web1
            User first
        Host web1
            User second
            Port 22022
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.user, "first")
        XCTAssertEqual(entries.first?.port, 22022)
    }

    // MARK: - Syntax variants

    func testEqualsSeparatorAndCaseInsensitiveKeywords() {
        let config = """
        HOST web1
            hostname=web1.example.com
            PORT = 2222
        """

        let entry = SSHConfigParser.parse(config).first

        XCTAssertEqual(entry?.hostName, "web1.example.com")
        XCTAssertEqual(entry?.port, 2222)
    }

    func testQuotedValuesAndComments() {
        let config = """
        # global comment
        Host "web 1"
            HostName web1.example.com
            # indented comment
            User deploy
        """

        let entry = SSHConfigParser.parse(config).first

        XCTAssertEqual(entry?.alias, "web 1")
        XCTAssertEqual(entry?.user, "deploy")
    }

    func testInvalidPortBecomesNil() {
        let config = """
        Host web1
            Port 99999
        Host web2
            Port abc
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertNil(entries[0].port)
        XCTAssertNil(entries[1].port)
    }

    func testMatchBlocksAreSkipped() {
        let config = """
        Host web1
            HostName web1.example.com
        Match user deploy
            Port 9999
        Host web2
            HostName web2.example.com
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries.map(\.alias), ["web1", "web2"])
        XCTAssertNil(entries[0].port)
        XCTAssertNil(entries[1].port)
    }

    // MARK: - Includes

    func testIncludeSplicesInPlace() {
        let main = """
        Include extra
        Host web1
            HostName web1.example.com
        """
        let extra = """
        Host db1
            HostName db1.example.com
        """

        let entries = SSHConfigParser.parse(main, includeResolver: { pattern in
            pattern == "extra" ? [extra] : []
        })

        XCTAssertEqual(entries.map(\.alias), ["db1", "web1"])
    }

    func testIncludeInsideHostBlockInheritsContext() {
        // OpenSSH splices included content at the directive, staying inside
        // the active Host block.
        let main = """
        Host web1
            Include web1-options
        """
        let options = "    HostName web1.example.com\n    Port 2222"

        let entry = SSHConfigParser.parse(main, includeResolver: { _ in [options] }).first

        XCTAssertEqual(entry?.hostName, "web1.example.com")
        XCTAssertEqual(entry?.port, 2222)
    }

    func testSelfReferentialIncludeTerminates() {
        // A resolver that always returns the same content simulates an
        // include cycle without a visited-set; the depth cap must stop it.
        let cyclic = "Include cycle\nHost web1\n"

        let entries = SSHConfigParser.parse(cyclic, includeResolver: { _ in [cyclic] })

        XCTAssertFalse(entries.isEmpty)
    }

    // MARK: - Glob matcher

    func testGlobMatching() {
        XCTAssertTrue(SSHConfigParser.glob("*", matches: "anything"))
        XCTAssertTrue(SSHConfigParser.glob("*.example.com", matches: "web1.example.com"))
        XCTAssertFalse(SSHConfigParser.glob("*.example.com", matches: "example.com"))
        XCTAssertTrue(SSHConfigParser.glob("web?", matches: "web1"))
        XCTAssertFalse(SSHConfigParser.glob("web?", matches: "web12"))
        XCTAssertTrue(SSHConfigParser.glob("a*b*c", matches: "aXbYc"))
        XCTAssertFalse(SSHConfigParser.glob("a*b*c", matches: "aXbY"))
    }

    func testGlobIsCaseSensitiveLikeOpenSSH() {
        // Verified against ssh -G: `Host WEB*` does not apply to `web1`.
        XCTAssertFalse(SSHConfigParser.glob("Web1", matches: "web1"))
        XCTAssertFalse(SSHConfigParser.glob("WEB*", matches: "web1"))
    }

    // MARK: - Regressions confirmed against ssh -G

    func testCRLFLineEndingsParse() {
        let config = "Host web1\r\n    HostName web1.example.com\r\n    Port 2222\r\n    User deploy\r\n"

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries, [SSHConfigHostEntry(
            alias: "web1",
            hostName: "web1.example.com",
            user: "deploy",
            port: 2222
        )])
    }

    func testEqualsGluedToValueSeparates() {
        // All separator spellings ssh accepts: `Port 22`, `Port=22`,
        // `Port = 22`, and `Port =2222`.
        let config = """
        Host web1
            HostName =real.example.com
            Port =2222
        """

        let entry = SSHConfigParser.parse(config).first

        XCTAssertEqual(entry?.hostName, "real.example.com")
        XCTAssertEqual(entry?.port, 2222)
    }

    func testCaseSensitiveWildcardStanzaDoesNotLeak() {
        // ssh -G web1: port 22 — `Host WEB*` must not apply.
        let config = """
        Host WEB*
            Port 9999
        Host web1
            HostName web1.example.com
        """

        XCTAssertNil(SSHConfigParser.parse(config).first { $0.alias == "web1" }?.port)
    }

    func testSameAliasDifferentCaseAreDistinctHosts() {
        let config = """
        Host Web1
            Port 1111
        Host web1
            Port 2222
        """

        let entries = SSHConfigParser.parse(config)

        XCTAssertEqual(entries.map(\.alias), ["Web1", "web1"])
        XCTAssertEqual(entries.map(\.port), [1111, 2222])
    }

    func testHostContextResumesAfterInclude() {
        // ssh -G outer1 resolves port 4444: the outer Host block's context
        // continues after the included file, even though the include opened
        // its own Host block.
        let main = """
        Host outer1
            Include frag1
            Port 4444
        """
        let frag1 = """
            HostName inner.example.com
        Host inner2
            Port 3333
        """

        let entries = SSHConfigParser.parse(main, includeResolver: { _ in [frag1] })

        let outer = entries.first { $0.alias == "outer1" }
        XCTAssertEqual(outer?.port, 4444)
        XCTAssertEqual(outer?.hostName, "inner.example.com")
    }

    func testHostBlockInsideNonMatchingIncludeIsScopedOut() {
        // ssh -G inner2 resolves port 22: an include under `Host outer1`
        // is only read for hosts matching outer1, so inner2's stanza is
        // unreachable and inner2 is not an importable alias.
        let main = """
        Host outer1
            Include frag1
        """
        let frag1 = """
        Host inner2
            Port 3333
        """

        let entries = SSHConfigParser.parse(main, includeResolver: { _ in [frag1] })

        XCTAssertNil(entries.first { $0.alias == "inner2" })
    }

    func testTopLevelContextResumesAfterInclude() {
        // ssh -G other resolves user uafter: options after a top-level
        // include are global again, not part of the include's last block.
        let main = """
        Include frag2
        User uafter
        Host other
        """
        let frag2 = """
        Host inc1
            Port 5555
        """

        let entries = SSHConfigParser.parse(main, includeResolver: { _ in [frag2] })

        XCTAssertEqual(entries.first { $0.alias == "other" }?.user, "uafter")
        // ssh -G inc1 also resolves user uafter: once global context
        // resumes, its options apply to every host, included ones too.
        XCTAssertEqual(entries.first { $0.alias == "inc1" }?.port, 5555)
        XCTAssertEqual(entries.first { $0.alias == "inc1" }?.user, "uafter")
    }

    func testSameFileIncludedAtTwoSitesAppliesTwice() {
        // OpenSSH re-reads a file included at multiple sites; a shared
        // fragment must reach both hosts.
        let main = """
        Host a
            Include shared
        Host b
            Include shared
        """
        let shared = "    User admin\n    Port 2222"

        let entries = SSHConfigParser.parse(main, includeResolver: { _ in [shared] })

        XCTAssertEqual(entries.map(\.user), ["admin", "admin"])
        XCTAssertEqual(entries.map(\.port), [2222, 2222])
    }
}
