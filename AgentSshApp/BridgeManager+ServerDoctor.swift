import Foundation
import AgentSshMacOS

enum ServerDoctorBridgeError: Error, LocalizedError {
    case connectionNotFound(String)
    case invalidRequest(String)
    case collectorFailed(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id): return "Connection not found: \(id)"
        case .invalidRequest(let message): return "Invalid Doctor request: \(message)"
        case .collectorFailed(let message): return "Doctor collection failed: \(message)"
        case .other(let message): return message
        }
    }

    static func from(_ error: FfiDoctorError) -> ServerDoctorBridgeError {
        switch error {
        case .ConnectionNotFound(let id):
            return .connectionNotFound(id)
        case .InvalidRequest(let message):
            return .invalidRequest(message)
        case .CollectorFailed(let message):
            return .collectorFailed(message)
        }
    }
}

extension BridgeManager {
    func serverDoctorPreview(
        request: ServerDoctorCollectionRequest
    ) async throws -> ServerDoctorCollectionPreview {
        let ffiRequest = request.ffiRequest
        let preview: FfiDoctorCollectionPreview = try await serverDoctorWrapping {
            try rshellDoctorPreview(request: ffiRequest)
        }
        return ServerDoctorCollectionPreview(
            request: request,
            plannedCommands: preview.plannedCommands.map(\.serverDoctorModel),
            possibleFileSources: preview.possibleFileSources,
            notes: preview.notes
        )
    }

    func serverDoctorCollect(
        request: ServerDoctorCollectionRequest
    ) async throws -> ServerDoctorCollectionBundle {
        let ffiRequest = request.ffiRequest
        let bundle: FfiDoctorCollectionBundle = try await serverDoctorWrapping {
            try rshellDoctorCollect(request: ffiRequest)
        }
        return bundle.serverDoctorModel(hostLabel: request.hostLabel)
    }

    private func serverDoctorWrapping<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            serverDoctorQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let error as FfiDoctorError {
                    continuation.resume(throwing: ServerDoctorBridgeError.from(error))
                } catch {
                    continuation.resume(throwing: ServerDoctorBridgeError.other(error.localizedDescription))
                }
            }
        }
    }
}

private let serverDoctorQueue: DispatchQueue = {
    DispatchQueue(
        label: "com.mc-ssh.bridge.server-doctor",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
}()

private extension ServerDoctorCollectionRequest {
    var ffiRequest: FfiDoctorCollectRequest {
        FfiDoctorCollectRequest(
            connectionId: connectionId,
            profiles: profiles.map(\.ffiProfile),
            serviceName: serviceName,
            maxTotalBytes: UInt32(clamping: maxTotalBytes),
            perCommandTimeoutMs: UInt32(clamping: perCommandTimeoutMs),
            logLineLimit: UInt32(clamping: logLineLimit)
        )
    }
}

private extension ServerDoctorCollectorProfile {
    var ffiProfile: FfiDoctorCollectorProfile {
        switch self {
        case .host: return .host
        case .systemd: return .systemd
        case .nginx: return .nginx
        case .disk: return .disk
        }
    }
}

private extension FfiDoctorCollectorProfile {
    var serverDoctorModel: ServerDoctorCollectorProfile {
        switch self {
        case .host: return .host
        case .systemd: return .systemd
        case .nginx: return .nginx
        case .disk: return .disk
        }
    }
}

private extension FfiDoctorEvidenceKind {
    var serverDoctorModel: ServerDoctorEvidenceKind {
        switch self {
        case .commandOutput: return .commandOutput
        case .logExcerpt: return .logExcerpt
        case .serviceStatus: return .serviceStatus
        case .metricSample: return .metricSample
        }
    }
}

private extension FfiDoctorPlannedCommand {
    var serverDoctorModel: ServerDoctorPlannedCommand {
        ServerDoctorPlannedCommand(
            id: id,
            profile: profile.serverDoctorModel,
            displayName: displayName,
            command: command
        )
    }
}

private extension FfiDoctorCommandAudit {
    var serverDoctorModel: ServerDoctorCommandAudit {
        ServerDoctorCommandAudit(
            id: id,
            collectorId: collectorId,
            profile: profile.serverDoctorModel,
            displayName: displayName,
            command: command,
            startedAt: Date(epochMilliseconds: startedAtEpochMs),
            durationMs: Int(durationMs),
            exitStatus: exitStatus.map(Int.init),
            stdoutBytes: Int(stdoutBytes),
            stderrBytes: Int(stderrBytes),
            truncated: truncated,
            permissionLimited: permissionLimited,
            readOnlyRisk: readOnlyRisk
        )
    }
}

private extension FfiDoctorEvidence {
    var serverDoctorModel: ServerDoctorEvidence {
        ServerDoctorEvidence(
            id: id,
            kind: kind.serverDoctorModel,
            title: title,
            source: source,
            collectedAt: Date(epochMilliseconds: collectedAtEpochMs),
            risk: risk,
            exitStatus: exitStatus.map(Int.init),
            excerpt: excerpt,
            rawOutput: rawOutput,
            rawRef: rawRef,
            byteCount: Int(byteCount),
            lineCount: Int(lineCount),
            truncated: truncated,
            permissionLimited: permissionLimited
        )
    }
}

private extension FfiDoctorWarning {
    var serverDoctorModel: ServerDoctorWarning {
        ServerDoctorWarning(id: id, message: message)
    }
}

private extension FfiDoctorCollectionBundle {
    func serverDoctorModel(hostLabel: String) -> ServerDoctorCollectionBundle {
        ServerDoctorCollectionBundle(
            id: id,
            hostLabel: hostLabel,
            collectedAt: Date(epochMilliseconds: collectedAtEpochMs),
            profiles: profiles.map(\.serverDoctorModel),
            commandAudits: commandAudits.map(\.serverDoctorModel),
            evidence: evidence.map(\.serverDoctorModel),
            warnings: warnings.map(\.serverDoctorModel)
        )
    }
}

private extension Date {
    init(epochMilliseconds: UInt64) {
        self.init(timeIntervalSince1970: TimeInterval(epochMilliseconds) / 1_000)
    }
}
