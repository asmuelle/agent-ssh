@testable import AgentSshApp
import Foundation
import Testing

/// Wire-level tests for the KEXINIT parser using synthetic packets,
/// plus the weak-algorithm classification used by the details panel.
struct SSHKexInitParserTests {
    // MARK: - Packet builders

    private func nameList(_ names: [String]) -> Data {
        let joined = Data(names.joined(separator: ",").utf8)
        return uint32(UInt32(joined.count)) + joined
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    /// Build a binary packet (RFC 4253 §6) around a payload.
    private func packet(payload: Data, paddingLength: UInt8 = 4) -> Data {
        let packetLength = UInt32(payload.count + Int(paddingLength) + 1)
        return uint32(packetLength)
            + Data([paddingLength])
            + payload
            + Data(repeating: 0, count: Int(paddingLength))
    }

    /// Build a KEXINIT payload (RFC 4253 §7.1) with the ten name-lists.
    private func kexInitPayload(
        kex: [String] = ["curve25519-sha256", "diffie-hellman-group14-sha1"],
        hostKeys: [String] = ["ssh-ed25519", "rsa-sha2-512"],
        macs: [String] = ["hmac-sha2-256-etm@openssh.com", "hmac-sha1"]
    ) -> Data {
        var payload = Data([20]) // SSH_MSG_KEXINIT
        payload += Data(repeating: 0xAB, count: 16) // cookie
        payload += nameList(kex)
        payload += nameList(hostKeys)
        payload += nameList(["aes256-gcm@openssh.com"]) // enc c2s
        payload += nameList(["aes256-gcm@openssh.com"]) // enc s2c
        payload += nameList(macs) // mac c2s
        payload += nameList(macs) // mac s2c
        payload += nameList(["none"]) // comp c2s
        payload += nameList(["none"]) // comp s2c
        payload += nameList([]) // lang c2s
        payload += nameList([]) // lang s2c
        payload += Data([0]) // first_kex_packet_follows
        payload += uint32(0) // reserved
        return payload
    }

    private let banner = Data("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3\r\n".utf8)

    // MARK: - Parsing

    @Test("parses banner, KEX algorithms, and MACs from a full exchange")
    func parsesFullExchange() throws {
        let wire = banner + packet(payload: kexInitPayload())

        let result = try #require(try SSHKexInitParser.parse(wire))

        #expect(result.serverBanner == "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3")
        #expect(result.kexAlgorithms == ["curve25519-sha256", "diffie-hellman-group14-sha1"])
        #expect(result.hostKeyAlgorithms == ["ssh-ed25519", "rsa-sha2-512"])
        #expect(result.macs == ["hmac-sha2-256-etm@openssh.com", "hmac-sha1"])
    }

    @Test("returns nil while the buffer is incomplete, at every byte boundary")
    func incompleteBufferReturnsNil() throws {
        let wire = banner + packet(payload: kexInitPayload())

        // Every strict prefix must be "keep waiting", not an error.
        for length in 0 ..< (wire.count - 1) {
            #expect(try SSHKexInitParser.parse(wire.prefix(length)) == nil)
        }
        #expect(try SSHKexInitParser.parse(wire) != nil)
    }

    @Test("skips pre-banner lines servers print before the SSH- line")
    func skipsPreBannerChatter() throws {
        let wire = Data("Welcome to example.com\r\n".utf8)
            + banner
            + packet(payload: kexInitPayload())

        let result = try #require(try SSHKexInitParser.parse(wire))
        #expect(result.serverBanner == "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3")
    }

    @Test("skips non-KEXINIT packets such as SSH_MSG_IGNORE")
    func skipsIgnorePackets() throws {
        let ignore = packet(payload: Data([2, 0, 0, 0, 0])) // SSH_MSG_IGNORE
        let wire = banner + ignore + packet(payload: kexInitPayload())

        let result = try #require(try SSHKexInitParser.parse(wire))
        #expect(result.kexAlgorithms.first == "curve25519-sha256")
    }

    @Test("rejects absurd packet lengths instead of buffering forever")
    func rejectsGarbagePacketLength() {
        // HTTP response masquerading as an SSH-ish stream: after a fake
        // banner line, "HTTP" bytes decode to a packet length way past
        // the RFC cap.
        let wire = banner + Data("HTTP/1.1 400 Bad Request".utf8)

        #expect(throws: SSHKexInitParser.ParseError.unexpectedlyLargePacket) {
            try SSHKexInitParser.parse(wire)
        }
    }

    @Test("differing per-direction MAC lists merge without duplicates")
    func macsMergeAcrossDirections() {
        let algorithms = SSHServerAlgorithms(
            serverBanner: "SSH-2.0-Test",
            kexAlgorithms: [],
            hostKeyAlgorithms: [],
            macsClientToServer: ["hmac-sha2-256", "hmac-sha1"],
            macsServerToClient: ["hmac-sha2-256", "hmac-sha2-512"]
        )

        #expect(algorithms.macs == ["hmac-sha2-256", "hmac-sha1", "hmac-sha2-512"])
    }
}

struct SSHAlgorithmStrengthTests {
    @Test(
        "flags deprecated KEX algorithms",
        arguments: [
            ("diffie-hellman-group1-sha1", true),
            ("diffie-hellman-group14-sha1", true),
            ("gss-group1-sha1-toWM5Slw5Ew8Mqkay+al2g==", true),
            ("curve25519-sha256", false),
            ("diffie-hellman-group16-sha512", false),
            ("sntrup761x25519-sha512@openssh.com", false),
        ]
    )
    func weakKex(testCase: (name: String, weak: Bool)) {
        #expect(SSHAlgorithmStrength.isWeakKex(testCase.name) == testCase.weak)
    }

    @Test(
        "flags deprecated MACs",
        arguments: [
            ("hmac-md5", true),
            ("hmac-md5-etm@openssh.com", true),
            ("hmac-sha1", true),
            ("hmac-sha1-etm@openssh.com", true),
            ("hmac-sha2-256-96", true),
            ("hmac-sha2-256-etm@openssh.com", false),
            ("hmac-sha2-512", false),
            ("umac-128-etm@openssh.com", false),
        ]
    )
    func weakMac(testCase: (name: String, weak: Bool)) {
        #expect(SSHAlgorithmStrength.isWeakMac(testCase.name) == testCase.weak)
    }
}
