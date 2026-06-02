import Foundation
import AgentSshMacOS

enum PortForwardBridgeError: Error, LocalizedError {
    case connectionNotFound(String)
    case invalidConfig(String)
    case unsupported(String)
    case notFound(String)
    case bind(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id):
            return "Connection not found: \(id)"
        case .invalidConfig(let message):
            return message
        case .unsupported(let message):
            return message
        case .notFound(let id):
            return "Port forward not found: \(id)"
        case .bind(let message):
            return "Could not bind local port: \(message)"
        case .other(let message):
            return message
        }
    }

    static func from(_ error: FfiPortForwardError) -> PortForwardBridgeError {
        switch error {
        case .ConnectionNotFound(let id):
            return .connectionNotFound(id)
        case .InvalidConfig(let message):
            return .invalidConfig(message)
        case .Unsupported(let message):
            return .unsupported(message)
        case .NotFound(let id):
            return .notFound(id)
        case .Bind(let message):
            return .bind(message)
        }
    }
}

extension BridgeManager {
    func portForwardStart(
        profile: PortForwardProfileRecord,
        connectionId: String
    ) async throws -> PortForwardRuntimeRecord {
        try await portForwardWrapping {
            let config = FfiPortForwardConfig(
                id: profile.id,
                profileId: profile.profileId,
                connectionId: connectionId,
                name: profile.name,
                kind: profile.kind.ffiKind,
                bindHost: profile.bindHost,
                bindPort: profile.bindPort,
                destinationHost: profile.destinationHost,
                destinationPort: profile.destinationPort
            )
            return try rshellPortForwardStart(config: config).runtimeRecord
        }
    }

    func portForwardStop(id: String) async throws {
        try await portForwardWrapping {
            try rshellPortForwardStop(id: id)
        }
    }

    func portForwardList(connectionId: String? = nil) async -> [PortForwardRuntimeRecord] {
        await withCheckedContinuation { continuation in
            portForwardQueue.async {
                continuation.resume(
                    returning: rshellPortForwardList(connectionId: connectionId).map(\.runtimeRecord)
                )
            }
        }
    }

    func portForwardStatus(id: String) async throws -> PortForwardRuntimeRecord {
        try await portForwardWrapping {
            try rshellPortForwardStatus(id: id).runtimeRecord
        }
    }

    private func portForwardWrapping<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            portForwardQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let error as FfiPortForwardError {
                    continuation.resume(throwing: PortForwardBridgeError.from(error))
                } catch {
                    continuation.resume(throwing: PortForwardBridgeError.other(error.localizedDescription))
                }
            }
        }
    }
}

private let portForwardQueue: DispatchQueue = {
    DispatchQueue(
        label: "com.mc-ssh.bridge.port-forwarding",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
}()

extension PortForwardKind {
    var ffiKind: FfiPortForwardKind {
        switch self {
        case .local:
            return .local
        case .remote:
            return .remote
        case .dynamicSocks:
            return .dynamicSocks
        }
    }
}

private extension FfiPortForwardKind {
    var modelKind: PortForwardKind {
        switch self {
        case .local:
            return .local
        case .remote:
            return .remote
        case .dynamicSocks:
            return .dynamicSocks
        }
    }
}

private extension FfiPortForwardStatus {
    var runtimeRecord: PortForwardRuntimeRecord {
        PortForwardRuntimeRecord(
            id: id,
            profileId: profileId,
            connectionId: connectionId,
            name: name,
            kind: kind.modelKind,
            state: .running,
            bindHost: bindHost,
            requestedBindPort: bindPort,
            boundPort: boundPort,
            destinationHost: destinationHost,
            destinationPort: destinationPort,
            startedAt: Date(timeIntervalSince1970: TimeInterval(startedAtUnix)),
            updatedAt: Date(),
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            connectionCount: connectionCount,
            lastError: lastError
        )
    }
}
