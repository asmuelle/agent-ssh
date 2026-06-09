import Foundation
import Testing
@testable import AgentSshApp

/// Tests for `RemoteIPParser`, extracted from the former monolithic
/// `SystemMonitorView.swift`. It parses the tab-separated `CONNECTED` /
/// `BANNED` lines emitted by the world-map remote script, pulling a public
/// IP out of each line and discarding private / reserved / malformed entries.
struct RemoteIPParserTests {
    // MARK: - Classification

    @Test("Classifies CONNECTED and BANNED lines into their buckets")
    func classifiesByTag() {
        let output = "CONNECTED\t8.8.8.8\nBANNED\t1.1.1.1"
        let result = RemoteIPParser.parse(output)
        #expect(result.connected == ["8.8.8.8"])
        #expect(result.banned == ["1.1.1.1"])
    }

    @Test("Ignores lines without a tab separator or with an unknown tag")
    func ignoresMalformedLines() {
        let output = """
        garbage-without-a-tab
        UNKNOWN\t8.8.8.8
        CONNECTED\t1.1.1.1
        """
        let result = RemoteIPParser.parse(output)
        #expect(result.connected == ["1.1.1.1"])
        #expect(result.banned.isEmpty)
    }

    // MARK: - Private / reserved filtering

    @Test(
        "Drops private, loopback, link-local, CGNAT and TEST-NET addresses",
        arguments: [
            "10.0.0.1",        // RFC1918
            "192.168.1.1",     // RFC1918
            "172.16.5.4",      // RFC1918
            "127.0.0.1",       // loopback
            "169.254.1.1",     // link-local
            "100.64.0.1",      // CGNAT
            "203.0.113.7",     // TEST-NET-3
            "0.0.0.0",         // "this host"
            "224.0.0.1",       // multicast
        ]
    )
    func dropsNonPublicIPv4(_ ip: String) {
        let result = RemoteIPParser.parse("CONNECTED\t\(ip)")
        #expect(result.connected.isEmpty, "\(ip) should be filtered as non-public")
    }

    @Test("Keeps genuinely public IPv4 addresses")
    func keepsPublicIPv4() {
        let result = RemoteIPParser.parse("CONNECTED\t45.33.32.156")
        #expect(result.connected == ["45.33.32.156"])
    }

    // MARK: - Extraction from noisy fields

    @Test("Strips CIDR suffix, port, and surrounding text to find the IP")
    func extractsFromNoisyFields() {
        let output = """
        CONNECTED\t45.33.32.156/32
        BANNED\tfrom 1.1.1.1 port 22
        CONNECTED\t8.8.8.8:443
        """
        let result = RemoteIPParser.parse(output)
        #expect(result.connected == ["45.33.32.156", "8.8.8.8"])
        #expect(result.banned == ["1.1.1.1"])
    }

    // MARK: - IPv6

    @Test("Extracts a public IPv6 address from bracket notation")
    func extractsBracketedIPv6() {
        let result = RemoteIPParser.parse("CONNECTED\t[2606:4700:4700::1111]")
        #expect(result.connected == ["2606:4700:4700::1111"])
    }

    @Test(
        "Filters non-public IPv6 (loopback, link-local, ULA, multicast, doc range)",
        arguments: ["[::1]", "[fe80::1]", "[fd00::1]", "[ff02::1]", "[2001:db8::1]"]
    )
    func dropsNonPublicIPv6(_ field: String) {
        let result = RemoteIPParser.parse("BANNED\t\(field)")
        #expect(result.banned.isEmpty, "\(field) should be filtered")
    }

    // MARK: - Dedup

    @Test("Deduplicates within each bucket, preserving first-seen order")
    func deduplicatesPerBucket() {
        let output = """
        CONNECTED\t8.8.8.8
        CONNECTED\t1.1.1.1
        CONNECTED\t8.8.8.8
        """
        let result = RemoteIPParser.parse(output)
        #expect(result.connected == ["8.8.8.8", "1.1.1.1"])
    }

    @Test("unique() removes duplicates while preserving order")
    func uniquePreservesOrder() {
        #expect(RemoteIPParser.unique(["a", "b", "a", "c", "b"]) == ["a", "b", "c"])
        #expect(RemoteIPParser.unique([]).isEmpty)
    }

    @Test("Returns empty buckets for empty input")
    func handlesEmptyInput() {
        let result = RemoteIPParser.parse("")
        #expect(result.connected.isEmpty)
        #expect(result.banned.isEmpty)
    }
}
