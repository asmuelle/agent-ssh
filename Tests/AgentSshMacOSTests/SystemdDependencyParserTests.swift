import Testing
@testable import AgentSshMacOS

struct SystemdDependencyParserTests {
    @Test("Plain forward listing parses root, depth, and names")
    func plainForwardListing() {
        let output = """
        nginx.service
          system.slice
          sysinit.target
            systemd-journald.socket
            systemd-tmpfiles-setup.service
          network-online.target
            NetworkManager-wait-online.service
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.rootUnit == "nginx.service")
        #expect(listing.directDependencies == ["system.slice", "sysinit.target", "network-online.target"])
        #expect(listing.nodes.first { $0.name == "systemd-journald.socket" }?.depth == 2)
        #expect(listing.allUnits.count == 7)
    }

    @Test("Tree glyphs and state bullets from non-plain output are tolerated")
    func glyphOutputTolerated() {
        let output = """
        nginx.service
        ● ├─system.slice
        ● └─sysinit.target
        ●   └─systemd-journald.socket
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.rootUnit == "nginx.service")
        #expect(listing.directDependencies == ["system.slice", "sysinit.target"])
        #expect(listing.nodes.first { $0.name == "systemd-journald.socket" }?.depth == 2)
    }

    @Test("Reverse listing parses the same shape — these are the dependents")
    func reverseListing() {
        let output = """
        postgresql.service
          app.service
          worker.service
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.rootUnit == "postgresql.service")
        #expect(listing.directDependencies == ["app.service", "worker.service"])
    }

    @Test("Non-unit noise lines are skipped, not parsed as units")
    func noiseLinesSkipped() {
        let output = """
        nginx.service
          system.slice
        Failed to get properties: Access denied
          -.mount
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.allUnits == ["nginx.service", "system.slice", "-.mount"])
    }

    @Test("Template instances and unusual unit names survive")
    func templateUnitsSurvive() {
        let output = """
        multi-user.target
          getty@tty1.service
          dbus-org.freedesktop.login1.service
          -.slice
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.directDependencies.contains("getty@tty1.service"))
        #expect(listing.directDependencies.contains("dbus-org.freedesktop.login1.service"))
        #expect(listing.directDependencies.contains("-.slice"))
    }

    @Test("Services helper filters the unit zoo down to .service units")
    func servicesHelper() {
        let output = """
        nginx.service
          system.slice
          php-fpm.service
          network-online.target
        """
        #expect(SystemdDependencyParser.parse(output).services == ["nginx.service", "php-fpm.service"])
    }

    @Test("ASCII-fallback trees from non-UTF-8 locales are skipped, not mis-parsed")
    func asciiFallbackLinesSkipped() {
        let output = """
        nginx.service
        |-system.slice
        `-sysinit.target
        o network.target
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.rootUnit == "nginx.service")
        #expect(listing.nodes.isEmpty)
    }

    @Test("Unit names starting with bullet-fallback letters are not corrupted")
    func bulletFallbackLettersDoNotEatUnitNames() {
        let listing = SystemdDependencyParser.parse("""
        multi-user.target
          openvpn.service
          xinetd.service
        """)
        #expect(listing.directDependencies == ["openvpn.service", "xinetd.service"])
    }

    @Test("Empty and whitespace-only output yields an empty listing")
    func emptyOutput() {
        #expect(SystemdDependencyParser.parse("").rootUnit == nil)
        #expect(SystemdDependencyParser.parse("  \n\n").nodes.isEmpty)
    }

    @Test("Duplicate units are reported once in allUnits, order preserved")
    func duplicatesCollapsedInAllUnits() {
        let output = """
        a.service
          shared.target
            common.service
          other.target
            common.service
        """
        let listing = SystemdDependencyParser.parse(output)
        #expect(listing.allUnits == ["a.service", "shared.target", "common.service", "other.target"])
    }
}
