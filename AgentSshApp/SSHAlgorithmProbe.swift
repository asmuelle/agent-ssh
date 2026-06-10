import Foundation
import Network

// MARK: - Model

/// Algorithms a server offers in its `SSH_MSG_KEXINIT` (RFC 4253 §7.1).
/// The KEXINIT is exchanged in plaintext before encryption starts, so a
/// bare TCP probe can read it without authenticating — the same trick
/// `nmap ssh2-enum-algos` uses.
struct SSHServerAlgorithms: Equatable {
    /// Server identification line, e.g. `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3`.
    let serverBanner: String
    let kexAlgorithms: [String]
    let hostKeyAlgorithms: [String]
    let macsClientToServer: [String]
    let macsServerToClient: [String]

    /// MACs for display. Servers almost always offer the same list in
    /// both directions; when they differ, show the (deduplicated) union.
    var macs: [String] {
        if macsClientToServer == macsServerToClient {
            return macsClientToServer
        }
        var seen = Set<String>()
        return (macsClientToServer + macsServerToClient).filter { seen.insert($0).inserted }
    }
}

// MARK: - Weak-algorithm classification

/// Conservative "should raise an eyebrow" lists, aligned with current
/// OpenSSH deprecations: SHA-1-based KEX, 1024-bit group1, and MD5 /
/// SHA-1 / truncated-tag MACs.
enum SSHAlgorithmStrength {
    static func isWeakKex(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("group1-") || n.hasSuffix("-sha1") || n.contains("-sha1-")
    }

    static func isWeakMac(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("md5") || n.contains("ripemd") { return true }
        if n.contains("-96") { return true }
        return n == "hmac-sha1" || n == "hmac-sha1-etm@openssh.com"
    }
}

// MARK: - KEXINIT wire parsing

/// Pure parser over the raw bytes a server sends after TCP connect.
/// Kept side-effect free so it can be unit-tested with synthetic
/// packets.
enum SSHKexInitParser {
    enum ParseError: Error, Equatable {
        case malformedPacket
        case unexpectedlyLargePacket
    }

    private static let msgKexInit: UInt8 = 20
    /// RFC 4253 §6.1 — all implementations must handle ≤ 35000; anything
    /// bigger before key exchange is garbage or not SSH.
    private static let maxPacketLength: UInt32 = 35000

    /// Attempt to extract the banner and KEXINIT from an accumulating
    /// receive buffer. Returns `nil` while the buffer is merely
    /// incomplete; throws when the bytes can't be SSH.
    static func parse(_ buffer: Data) throws -> SSHServerAlgorithms? {
        // --- Identification exchange (RFC 4253 §4.2). The server may
        // send extra banner lines before its `SSH-` line.
        var cursor = buffer.startIndex
        var banner: String?
        while banner == nil {
            guard let newline = buffer[cursor...].firstIndex(of: UInt8(ascii: "\n")) else {
                // No full line yet — but cap how much pre-banner chatter
                // we're willing to buffer.
                if buffer.distance(from: cursor, to: buffer.endIndex) > 8192 {
                    throw ParseError.malformedPacket
                }
                return nil
            }
            let lineData = buffer[cursor ..< newline]
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = buffer.index(after: newline)
            if line.hasPrefix("SSH-") {
                banner = line
            }
        }
        guard let banner else { return nil }

        // --- Binary packets (RFC 4253 §6), unencrypted at this stage:
        // uint32 packet_length, byte padding_length, payload, padding.
        while true {
            let remaining = buffer.distance(from: cursor, to: buffer.endIndex)
            guard remaining >= 5 else { return nil }

            let packetLength = readUInt32(buffer, at: cursor)
            guard packetLength >= 2, packetLength <= maxPacketLength else {
                throw ParseError.unexpectedlyLargePacket
            }
            let total = 4 + Int(packetLength)
            guard remaining >= total else { return nil }

            let paddingLength = Int(buffer[buffer.index(cursor, offsetBy: 4)])
            let payloadLength = Int(packetLength) - paddingLength - 1
            guard payloadLength >= 1 else { throw ParseError.malformedPacket }

            let payloadStart = buffer.index(cursor, offsetBy: 5)
            let payload = buffer[payloadStart ..< buffer.index(payloadStart, offsetBy: payloadLength)]

            if payload.first == msgKexInit {
                return try parseKexInitPayload(Data(payload), banner: banner)
            }

            // Not KEXINIT (e.g. SSH_MSG_IGNORE) — skip to the next packet.
            cursor = buffer.index(cursor, offsetBy: total)
        }
    }

    /// KEXINIT payload (RFC 4253 §7.1): message byte, 16-byte cookie,
    /// then ten name-lists; we need #1 (kex), #2 (host keys), #5/#6
    /// (MACs).
    private static func parseKexInitPayload(
        _ payload: Data,
        banner: String
    ) throws -> SSHServerAlgorithms {
        var offset = payload.startIndex + 1 + 16 // message byte + cookie

        var lists: [[String]] = []
        for _ in 0 ..< 6 { // kex, hostkey, enc×2, mac×2
            guard payload.distance(from: offset, to: payload.endIndex) >= 4 else {
                throw ParseError.malformedPacket
            }
            let length = Int(readUInt32(payload, at: offset))
            offset = payload.index(offset, offsetBy: 4)
            guard payload.distance(from: offset, to: payload.endIndex) >= length else {
                throw ParseError.malformedPacket
            }
            let nameList = String(
                decoding: payload[offset ..< payload.index(offset, offsetBy: length)],
                as: UTF8.self
            )
            lists.append(nameList.isEmpty ? [] : nameList.components(separatedBy: ","))
            offset = payload.index(offset, offsetBy: length)
        }

        return SSHServerAlgorithms(
            serverBanner: banner,
            kexAlgorithms: lists[0],
            hostKeyAlgorithms: lists[1],
            macsClientToServer: lists[4],
            macsServerToClient: lists[5]
        )
    }

    private static func readUInt32(_ data: Data, at index: Data.Index) -> UInt32 {
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value = (value << 8) | UInt32(data[data.index(index, offsetBy: i)])
        }
        return value
    }
}

// MARK: - Network probe

/// Opens a TCP connection, completes the SSH identification exchange,
/// reads the server's KEXINIT, and disconnects — all pre-auth, nothing
/// is sent beyond our version string.
enum SSHAlgorithmProbe {
    enum ProbeError: LocalizedError {
        case timeout
        case connection(String)
        case notSSH

        var errorDescription: String? {
            switch self {
            case .timeout: return "Timed out"
            case let .connection(detail): return detail
            case .notSSH: return "Not an SSH server"
            }
        }
    }

    static func probe(
        host: String,
        port: UInt16,
        timeout: TimeInterval = 6
    ) async throws -> SSHServerAlgorithms {
        let session = ProbeSession(host: host, port: port, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }
    }
}

/// One probe attempt. NWConnection callbacks land on a private serial
/// queue; `finish` guards the single continuation resume.
private final class ProbeSession: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "ssh-algorithm-probe")

    private var connection: NWConnection?
    private var buffer = Data()
    private var continuation: CheckedContinuation<SSHServerAlgorithms, Error>?

    init(host: String, port: UInt16, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    func run() async throws -> SSHServerAlgorithms {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.start(continuation: continuation)
            }
        }
    }

    func cancel() {
        queue.async {
            self.finish(.failure(CancellationError()))
        }
    }

    private func start(continuation: CheckedContinuation<SSHServerAlgorithms, Error>) {
        self.continuation = continuation

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finish(.failure(SSHAlgorithmProbe.ProbeError.connection("Invalid port \(port)")))
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // RFC 4253 §4.2 — identification string, CR LF terminated.
                // Most servers send their KEXINIT right after seeing ours…
                connection.send(
                    content: Data("SSH-2.0-AgentSSH_Probe\r\n".utf8),
                    completion: .contentProcessed { _ in }
                )
                self.receiveNext()
            case let .failed(error):
                self.finish(.failure(SSHAlgorithmProbe.ProbeError.connection(error.localizedDescription)))
            case .cancelled:
                self.finish(.failure(CancellationError()))
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(SSHAlgorithmProbe.ProbeError.timeout))
        }

        connection.start(queue: queue)
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data {
                self.buffer.append(data)
            }

            do {
                if let algorithms = try SSHKexInitParser.parse(self.buffer) {
                    self.finish(.success(algorithms))
                    return
                }
            } catch {
                self.finish(.failure(SSHAlgorithmProbe.ProbeError.notSSH))
                return
            }

            if let error {
                self.finish(.failure(SSHAlgorithmProbe.ProbeError.connection(error.localizedDescription)))
            } else if isComplete {
                self.finish(.failure(SSHAlgorithmProbe.ProbeError.notSSH))
            } else {
                self.receiveNext()
            }
        }
    }

    private func finish(_ result: Result<SSHServerAlgorithms, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        connection?.cancel()
        connection = nil

        switch result {
        case let .success(algorithms): continuation.resume(returning: algorithms)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }
}

// MARK: - Session cache

/// One probe per host:port per app session. Keeps the details panel
/// snappy when flipping between connections, and avoids hammering
/// sshd with pre-auth connects (fail2ban-friendly).
@MainActor
final class SSHAlgorithmProbeCache: ObservableObject {
    static let shared = SSHAlgorithmProbeCache()

    enum State: Equatable {
        case loading
        case loaded(SSHServerAlgorithms)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    private var inFlight: Set<String> = []

    static func key(host: String, port: UInt16) -> String {
        "\(host):\(port)"
    }

    func state(host: String, port: UInt16) -> State? {
        states[Self.key(host: host, port: port)]
    }

    /// Probe unless a result (or attempt) already exists. `force`
    /// re-probes, for the retry affordance after a failure.
    func probeIfNeeded(host: String, port: UInt16, force: Bool = false) {
        let key = Self.key(host: host, port: port)
        if !force, states[key] != nil || inFlight.contains(key) { return }
        guard !inFlight.contains(key) else { return }

        inFlight.insert(key)
        states[key] = .loading

        // Explicit `@MainActor` so the post-`await` continuation that mutates
        // `states` (@Published) and `inFlight` is guaranteed to resume on the
        // main actor under Swift 6 strict concurrency, not just by relying on
        // `@_inheritActorContext`.
        Task { @MainActor [weak self] in
            do {
                let algorithms = try await SSHAlgorithmProbe.probe(host: host, port: port)
                self?.states[key] = .loaded(algorithms)
            } catch {
                self?.states[key] = .failed(error.localizedDescription)
            }
            self?.inFlight.remove(key)
        }
    }
}
