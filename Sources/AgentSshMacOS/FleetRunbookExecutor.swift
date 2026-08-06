import Foundation

public struct FleetRunTarget: Codable, Identifiable, Hashable, Sendable {
    public var profileId: String
    public var connectionId: String
    public var displayName: String

    public var id: String { profileId }

    public init(profileId: String, connectionId: String, displayName: String) {
        self.profileId = profileId
        self.connectionId = connectionId
        self.displayName = displayName
    }
}

public struct FleetRunbookPlan: Sendable {
    public var title: String
    public var command: String
    public var verificationCommand: String?
    public var rollbackCommand: String?
    public var externalVerificationLabel: String?
    public var targets: [FleetRunTarget]
    public var canaryCount: Int
    public var maxConcurrency: Int

    public init(
        title: String,
        command: String,
        verificationCommand: String? = nil,
        rollbackCommand: String? = nil,
        externalVerificationLabel: String? = nil,
        targets: [FleetRunTarget],
        canaryCount: Int = 1,
        maxConcurrency: Int = 3
    ) {
        self.title = title
        self.command = command
        self.verificationCommand = verificationCommand?.nilIfBlank
        self.rollbackCommand = rollbackCommand?.nilIfBlank
        self.externalVerificationLabel = externalVerificationLabel?.nilIfBlank
        self.targets = targets
        self.canaryCount = max(1, min(canaryCount, max(targets.count, 1)))
        self.maxConcurrency = max(1, maxConcurrency)
    }
}

public struct FleetCommandExecution: Equatable, Sendable {
    public var exitCode: Int
    public var output: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public enum FleetTargetRunState: String, Codable, Sendable {
    case succeeded
    case failed
    case verificationFailed
    case rolledBack
    case rollbackFailed
    case skipped

    public var succeeded: Bool { self == .succeeded }
}

public struct FleetTargetRunResult: Identifiable, Equatable, Sendable {
    public var target: FleetRunTarget
    public var state: FleetTargetRunState
    public var commandExitCode: Int?
    public var verificationExitCode: Int?
    public var rollbackExitCode: Int?
    public var output: String

    public var id: String { target.id }

    public init(
        target: FleetRunTarget,
        state: FleetTargetRunState,
        commandExitCode: Int? = nil,
        verificationExitCode: Int? = nil,
        rollbackExitCode: Int? = nil,
        output: String = ""
    ) {
        self.target = target
        self.state = state
        self.commandExitCode = commandExitCode
        self.verificationExitCode = verificationExitCode
        self.rollbackExitCode = rollbackExitCode
        self.output = output
    }
}

public struct FleetRunbookResult: Equatable, Sendable {
    public var title: String
    public var startedAt: Date
    public var finishedAt: Date
    public var abortedAfterCanary: Bool
    public var results: [FleetTargetRunResult]
}

public enum FleetRunbookExecutor {
    public typealias CommandRunner = @Sendable (
        _ target: FleetRunTarget,
        _ command: String
    ) async -> FleetCommandExecution
    public typealias ExternalVerificationRunner = @Sendable (
        _ target: FleetRunTarget
    ) async -> FleetCommandExecution

    public static func execute(
        plan: FleetRunbookPlan,
        runner: @escaping CommandRunner
    ) async -> FleetRunbookResult {
        await execute(plan: plan, runner: runner, externalVerifier: nil)
    }

    public static func execute(
        plan: FleetRunbookPlan,
        runner: @escaping CommandRunner,
        externalVerifier: ExternalVerificationRunner?
    ) async -> FleetRunbookResult {
        let startedAt = Date()
        guard !plan.targets.isEmpty else {
            return FleetRunbookResult(
                title: plan.title,
                startedAt: startedAt,
                finishedAt: Date(),
                abortedAfterCanary: false,
                results: []
            )
        }

        let canaryCount = min(plan.canaryCount, plan.targets.count)
        let canaries = Array(plan.targets.prefix(canaryCount))
        let rollout = Array(plan.targets.dropFirst(canaryCount))
        var results: [FleetTargetRunResult] = []

        // Canary targets are deliberately sequential. An operator should never
        // discover the same bad change on several hosts at once.
        for target in canaries {
            let result = await executeTarget(
                target,
                plan: plan,
                runner: runner,
                externalVerifier: externalVerifier
            )
            results.append(result)
            if !result.state.succeeded {
                results.append(contentsOf: rollout.map {
                    FleetTargetRunResult(target: $0, state: .skipped)
                })
                return FleetRunbookResult(
                    title: plan.title,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    abortedAfterCanary: true,
                    results: ordered(results, by: plan.targets)
                )
            }
        }

        // Execute rollout targets in bounded chunks. This provides a simple,
        // auditable upper bound without leaving detached tasks behind.
        var offset = 0
        while offset < rollout.count {
            let upper = min(offset + plan.maxConcurrency, rollout.count)
            let chunk = Array(rollout[offset..<upper])
            let chunkResults = await withTaskGroup(of: FleetTargetRunResult.self) { group in
                for target in chunk {
                    group.addTask {
                        await executeTarget(
                            target,
                            plan: plan,
                            runner: runner,
                            externalVerifier: externalVerifier
                        )
                    }
                }
                var collected: [FleetTargetRunResult] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            results.append(contentsOf: chunkResults)
            offset = upper
        }

        return FleetRunbookResult(
            title: plan.title,
            startedAt: startedAt,
            finishedAt: Date(),
            abortedAfterCanary: false,
            results: ordered(results, by: plan.targets)
        )
    }

    private static func executeTarget(
        _ target: FleetRunTarget,
        plan: FleetRunbookPlan,
        runner: @escaping CommandRunner,
        externalVerifier: ExternalVerificationRunner?
    ) async -> FleetTargetRunResult {
        let command = await runner(target, plan.command)
        guard command.succeeded else {
            return FleetTargetRunResult(
                target: target,
                state: .failed,
                commandExitCode: command.exitCode,
                output: command.output
            )
        }

        let verification: FleetCommandExecution?
        if let verificationCommand = plan.verificationCommand {
            verification = await runner(target, verificationCommand)
        } else if plan.externalVerificationLabel != nil {
            verification = await externalVerifier?(target) ?? FleetCommandExecution(
                exitCode: 78,
                output: "External verification was configured but no verifier was available."
            )
        } else {
            verification = nil
        }

        guard let verification else {
            return FleetTargetRunResult(
                target: target,
                state: .succeeded,
                commandExitCode: command.exitCode,
                output: command.output
            )
        }

        guard verification.succeeded else {
            guard let rollbackCommand = plan.rollbackCommand else {
                return FleetTargetRunResult(
                    target: target,
                    state: .verificationFailed,
                    commandExitCode: command.exitCode,
                    verificationExitCode: verification.exitCode,
                    output: joinedOutput(command.output, verification.output)
                )
            }

            let rollback = await runner(target, rollbackCommand)
            return FleetTargetRunResult(
                target: target,
                state: rollback.succeeded ? .rolledBack : .rollbackFailed,
                commandExitCode: command.exitCode,
                verificationExitCode: verification.exitCode,
                rollbackExitCode: rollback.exitCode,
                output: joinedOutput(command.output, verification.output, rollback.output)
            )
        }

        return FleetTargetRunResult(
            target: target,
            state: .succeeded,
            commandExitCode: command.exitCode,
            verificationExitCode: verification.exitCode,
            output: joinedOutput(command.output, verification.output)
        )
    }

    private static func ordered(
        _ results: [FleetTargetRunResult],
        by targets: [FleetRunTarget]
    ) -> [FleetTargetRunResult] {
        let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1.id, $0) })
        return results.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
    }

    private static func joinedOutput(_ values: String...) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
