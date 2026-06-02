import Foundation
import AgentSshMacOS

enum SecurityPatchBridgeError: Error, LocalizedError {
    case connectionNotFound(String)
    case invalidRequest(String)
    case collectorFailed(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id): return "Connection not found: \(id)"
        case .invalidRequest(let message): return "Invalid security scan request: \(message)"
        case .collectorFailed(let message): return "Security scan failed: \(message)"
        case .other(let message): return message
        }
    }

    static func from(_ error: FfiSecurityPatchError) -> SecurityPatchBridgeError {
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
    func securityPatchPreview(
        request: SecurityPatchScanRequest
    ) async throws -> SecurityPatchScanPreview {
        let ffiRequest = request.ffiRequest
        let preview: FfiSecurityPatchScanPreview = try await securityPatchWrapping {
            try rshellSecurityPatchPreview(request: ffiRequest)
        }
        return SecurityPatchScanPreview(
            request: request,
            plannedCommands: preview.plannedCommands.map(\.securityPatchModel),
            notes: preview.notes
        )
    }

    func securityPatchScan(
        request: SecurityPatchScanRequest
    ) async throws -> SecurityPatchScanBundle {
        let ffiRequest = request.ffiRequest
        let bundle: FfiSecurityPatchScanBundle = try await securityPatchWrapping {
            try rshellSecurityPatchScan(request: ffiRequest)
        }
        return bundle.securityPatchModel(
            connectionId: request.connectionId,
            profileId: request.profileId,
            hostLabel: request.hostLabel
        )
    }

    private func securityPatchWrapping<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            securityPatchQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch let error as FfiSecurityPatchError {
                    continuation.resume(throwing: SecurityPatchBridgeError.from(error))
                } catch {
                    continuation.resume(throwing: SecurityPatchBridgeError.other(error.localizedDescription))
                }
            }
        }
    }
}

private let securityPatchQueue: DispatchQueue = {
    DispatchQueue(
        label: "com.mc-ssh.bridge.security-patch",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
}()

private extension SecurityPatchScanRequest {
    var ffiRequest: FfiSecurityPatchScanRequest {
        FfiSecurityPatchScanRequest(
            connectionId: connectionId,
            profiles: profiles.map(\.ffiProfile),
            maxTotalBytes: UInt32(clamping: maxTotalBytes),
            perCommandTimeoutMs: UInt32(clamping: perCommandTimeoutMs),
            lineLimit: UInt32(clamping: lineLimit)
        )
    }
}

private extension SecurityPatchCollectorProfile {
    var ffiProfile: FfiSecurityPatchCollectorProfile {
        switch self {
        case .os: return .os
        case .packageManager: return .packageManager
        case .reboot: return .reboot
        case .sshd: return .sshd
        case .networkExposure: return .networkExposure
        }
    }
}

private extension FfiSecurityPatchCollectorProfile {
    var securityPatchModel: SecurityPatchCollectorProfile {
        switch self {
        case .os: return .os
        case .packageManager: return .packageManager
        case .reboot: return .reboot
        case .sshd: return .sshd
        case .networkExposure: return .networkExposure
        }
    }
}

private extension FfiSecurityPatchEvidenceKind {
    var securityPatchModel: SecurityPatchEvidenceKind {
        switch self {
        case .commandOutput: return .commandOutput
        case .osRelease: return .osRelease
        case .packageStatus: return .packageStatus
        case .rebootStatus: return .rebootStatus
        case .sshdConfig: return .sshdConfig
        case .networkExposure: return .networkExposure
        }
    }
}

private extension FfiSecurityPatchPlannedCommand {
    var securityPatchModel: SecurityPatchPlannedCommand {
        SecurityPatchPlannedCommand(
            id: id,
            profile: profile.securityPatchModel,
            displayName: displayName,
            command: command
        )
    }
}

private extension FfiSecurityPatchCommandAudit {
    var securityPatchModel: SecurityPatchCommandAudit {
        SecurityPatchCommandAudit(
            id: id,
            collectorId: collectorId,
            profile: profile.securityPatchModel,
            displayName: displayName,
            command: command,
            startedAt: Date(securityPatchEpochMilliseconds: startedAtEpochMs),
            durationMs: Int(durationMs),
            exitStatus: exitStatus.map(Int.init),
            stdoutBytes: Int(stdoutBytes),
            stderrBytes: Int(stderrBytes),
            truncated: truncated,
            permissionLimited: permissionLimited,
            risk: risk
        )
    }
}

private extension FfiSecurityPatchEvidence {
    var securityPatchModel: SecurityPatchEvidence {
        SecurityPatchEvidence(
            id: id,
            collectorId: collectorId,
            profile: profile.securityPatchModel,
            kind: kind.securityPatchModel,
            title: title,
            source: source,
            collectedAt: Date(securityPatchEpochMilliseconds: collectedAtEpochMs),
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

private extension FfiSecurityPatchWarning {
    var securityPatchModel: SecurityPatchWarning {
        SecurityPatchWarning(id: id, message: message)
    }
}

private extension FfiSecurityPatchScanBundle {
    func securityPatchModel(
        connectionId: String,
        profileId: String?,
        hostLabel: String
    ) -> SecurityPatchScanBundle {
        SecurityPatchScanBundle(
            id: id,
            connectionId: connectionId,
            profileId: profileId,
            hostLabel: hostLabel,
            scannedAt: Date(securityPatchEpochMilliseconds: scannedAtEpochMs),
            profiles: profiles.map(\.securityPatchModel),
            commandAudits: commandAudits.map(\.securityPatchModel),
            evidence: evidence.map(\.securityPatchModel),
            warnings: warnings.map(\.securityPatchModel)
        )
    }
}

private extension Date {
    init(securityPatchEpochMilliseconds: UInt64) {
        self.init(timeIntervalSince1970: TimeInterval(securityPatchEpochMilliseconds) / 1_000)
    }
}
