import Foundation
import OSLog
import AgentSshMacOS

#if canImport(WidgetKit)
import WidgetKit
#endif

final class WidgetMonitoringSnapshotCenter: @unchecked Sendable {
    static let shared = WidgetMonitoringSnapshotCenter()

    private let logger = Logger(subsystem: "com.mc-ssh", category: "widget-snapshots")
    private let queue = DispatchQueue(label: "com.mc-ssh.widget-snapshots", qos: .utility)
    private let store: WidgetSnapshotStore
    private let minimumTimestampWriteInterval: TimeInterval
    private let minimumTimelineReloadInterval: TimeInterval
    private let alertRules: [WidgetMonitorAlertRule]

    private var loaded = false
    private var snapshotsById: [String: WidgetMonitorSnapshot] = [:]
    private var lastPersistAt: Date?
    private var lastTimelineReloadAt: Date?
    private var pendingTimelineReload: DispatchWorkItem?
    private var alertHistory = WidgetMonitorAlertHistory()

    init(
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        minimumTimestampWriteInterval: TimeInterval = 60,
        minimumTimelineReloadInterval: TimeInterval = 30,
        alertRules: [WidgetMonitorAlertRule] = [.confirmedFailures]
    ) {
        self.store = store
        self.minimumTimestampWriteInterval = minimumTimestampWriteInterval
        self.minimumTimelineReloadInterval = minimumTimelineReloadInterval
        self.alertRules = alertRules
    }

    func bootstrap() {
        queue.async {
            self.loadIfNeeded()
            if self.snapshotsById.isEmpty {
                self.snapshotsById[WidgetMonitorSnapshot.placeholder().id] = .placeholder()
                self.persistAndMaybeReload(forceWrite: true)
            } else if self.compactSupersededSnapshots() {
                self.persistAndMaybeReload(forceWrite: true)
            } else {
                self.persistAndMaybeReload(forceWrite: true)
            }
        }
    }

    func reloadTimelines() {
        queue.async {
            self.scheduleTimelineReload()
        }
    }

    func upsert(_ snapshot: WidgetMonitorSnapshot) {
        queue.async {
            self.loadIfNeeded()
            let previousSignature = self.semanticSignature()

            if snapshot.id != WidgetMonitorSnapshot.placeholder().id {
                self.snapshotsById.removeValue(forKey: WidgetMonitorSnapshot.placeholder().id)
            }
            self.removeSupersededSnapshots(for: snapshot)

            let previous = self.snapshotsById[snapshot.id]
            self.snapshotsById[snapshot.id] = snapshot
            let alertDecisions = self.alertDecisions(for: [snapshot], previousSnapshots: previous.map { [snapshot.id: $0] } ?? [:])

            let semanticChanged = previousSignature != self.semanticSignature()
            if !semanticChanged,
               previous != nil,
               !self.shouldPersistTimestampOnlyUpdate() {
                return
            }

            self.persistAndMaybeReload(forceWrite: semanticChanged || previous != snapshot)
            self.deliverAlertDecisions(alertDecisions)
        }
    }

    func remove(id: String) {
        queue.async {
            self.loadIfNeeded()
            guard self.snapshotsById.removeValue(forKey: id) != nil else { return }
            self.persistAndMaybeReload(forceWrite: true)
        }
    }

    func replaceSnapshots(matchingPrefix prefix: String, with snapshots: [WidgetMonitorSnapshot]) {
        queue.async {
            self.loadIfNeeded()
            let previousSignature = self.semanticSignature()

            let previousSnapshots = self.snapshotsById

            self.snapshotsById = self.snapshotsById.filter { key, _ in
                !key.hasPrefix(prefix)
            }

            if !snapshots.isEmpty {
                self.snapshotsById.removeValue(forKey: WidgetMonitorSnapshot.placeholder().id)
            }

            for snapshot in snapshots {
                self.snapshotsById[snapshot.id] = snapshot
            }
            let alertDecisions = self.alertDecisions(for: snapshots, previousSnapshots: previousSnapshots)

            let semanticChanged = previousSignature != self.semanticSignature()
            if !semanticChanged, !self.shouldPersistTimestampOnlyUpdate() {
                return
            }

            self.persistAndMaybeReload(forceWrite: true)
            self.deliverAlertDecisions(alertDecisions)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        defer { loaded = true }

        do {
            let snapshotFile = try store.loadSnapshotFile()
            snapshotsById = Dictionary(
                uniqueKeysWithValues: (snapshotFile?.snapshots ?? []).map { ($0.id, $0) }
            )
        } catch WidgetSnapshotStoreError.appGroupContainerUnavailable {
            snapshotsById = [:]
        } catch {
            logger.warning("Failed to load widget snapshots: \(error.localizedDescription, privacy: .public)")
            snapshotsById = [:]
        }
    }

    @discardableResult
    private func persistAndMaybeReload(forceWrite: Bool) -> Bool {
        guard forceWrite else { return false }

        let snapshots = snapshotsForWrite()

        do {
            try store.saveSnapshots(snapshots)
            lastPersistAt = Date()
        } catch WidgetSnapshotStoreError.appGroupContainerUnavailable(let identifier) {
            logger.warning("Widget App Group unavailable: \(identifier, privacy: .public)")
            return false
        } catch {
            logger.warning("Failed to save widget snapshots: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // WidgetKit can keep serving an older placeholder timeline even after
        // the shared snapshot file contains real checks. Every persisted write
        // should ask the widget to re-read the file; scheduleTimelineReload()
        // still coalesces calls via minimumTimelineReloadInterval.
        scheduleTimelineReload()
        return true
    }

    private func alertDecisions(
        for snapshots: [WidgetMonitorSnapshot],
        previousSnapshots: [String: WidgetMonitorSnapshot]
    ) -> [WidgetMonitorAlertDecision] {
        WidgetMonitorAlertEvaluator.decisions(
            for: snapshots,
            previousSnapshots: previousSnapshots,
            history: alertHistory,
            rules: alertRules
        )
    }

    private func deliverAlertDecisions(_ decisions: [WidgetMonitorAlertDecision]) {
        guard !decisions.isEmpty else { return }

        MonitoringAlertNotificationCenter.shared.deliver(decisions) { [weak self] decision in
            self?.queue.async {
                self?.alertHistory.record(
                    ruleId: decision.ruleId,
                    snapshotId: decision.snapshotId,
                    deliveredAt: Date()
                )
            }
        }
    }

    private func snapshotsForWrite() -> [WidgetMonitorSnapshot] {
        let snapshots = snapshotsById.values
            .filter { $0.id != WidgetMonitorSnapshot.placeholder().id }
            .sorted { $0.id < $1.id }

        if snapshots.isEmpty {
            return [.placeholder()]
        }
        return snapshots
    }

    private func removeSupersededSnapshots(for snapshot: WidgetMonitorSnapshot) {
        if let replacementScope = snapshot.replacementScope {
            let scopesById = snapshotsById.mapValues(\.replacementScope)
            snapshotsById = snapshotsById.filter { key, _ in
                key == snapshot.id || scopesById[key] != replacementScope
            }
        }
    }

    @discardableResult
    private func compactSupersededSnapshots() -> Bool {
        var compacted: [String: WidgetMonitorSnapshot] = [:]
        var scopedSnapshots: [String: WidgetMonitorSnapshot] = [:]

        for snapshot in snapshotsById.values {
            guard let scope = snapshot.replacementScope else {
                compacted[snapshot.id] = snapshot
                continue
            }

            if let existing = scopedSnapshots[scope] {
                scopedSnapshots[scope] = existing.isOlder(than: snapshot) ? snapshot : existing
            } else {
                scopedSnapshots[scope] = snapshot
            }
        }

        for snapshot in scopedSnapshots.values {
            compacted[snapshot.id] = snapshot
        }

        guard compacted != snapshotsById else { return false }
        snapshotsById = compacted
        return true
    }

    private func shouldPersistTimestampOnlyUpdate(now: Date = Date()) -> Bool {
        guard let lastPersistAt else { return true }
        return now.timeIntervalSince(lastPersistAt) >= minimumTimestampWriteInterval
    }

    private func semanticSignature() -> String {
        semanticSignature(for: snapshotsForWrite())
    }

    private func semanticSignature(for snapshots: [WidgetMonitorSnapshot]) -> String {
        snapshots
            .sorted { $0.id < $1.id }
            .map { snapshot in
                [
                    snapshot.id,
                    snapshot.displayName,
                    snapshot.kind.rawValue,
                    snapshot.state.rawValue,
                    snapshot.summary,
                    snapshot.detail ?? "",
                    snapshot.openURL ?? "",
                ].joined(separator: "\u{1F}")
            }
            .joined(separator: "\u{1E}")
    }

    private func scheduleTimelineReload() {
        #if canImport(WidgetKit)
        guard pendingTimelineReload == nil else { return }

        let now = Date()
        let delay: TimeInterval
        if let lastTimelineReloadAt {
            delay = max(0, minimumTimelineReloadInterval - now.timeIntervalSince(lastTimelineReloadAt))
        } else {
            delay = 0
        }

        let workItem = DispatchWorkItem { [weak self] in
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.widgetKind)
            WidgetCenter.shared.reloadAllTimelines()
            self?.queue.async {
                self?.lastTimelineReloadAt = Date()
                self?.pendingTimelineReload = nil
            }
        }
        pendingTimelineReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        #endif
    }
}

extension WidgetMonitorSnapshot {
    static func sshConnection(
        profile: ConnectionProfile,
        connectionId: String,
        status: TerminalConnectionStatus,
        effectiveKind: ConnectionKind? = nil,
        detail: String? = nil,
        now: Date = Date()
    ) -> WidgetMonitorSnapshot {
        let state = WidgetSnapshotStateClassifier.state(forTerminalStatus: status)
        let kind = effectiveKind ?? profile.kind
        return WidgetMonitorSnapshot(
            id: "ssh:\(profile.id)",
            displayName: profile.name,
            kind: kind == .sftp ? .sftp : .host,
            state: state,
            lastCheckedAt: status == .connecting ? nil : now,
            lastChangedAt: now,
            summary: sshSummary(status: status, kind: kind),
            detail: detail,
            openURL: "agent-ssh://monitoring/\(profile.id)"
        )
    }

    static func sshFailure(
        profile: ConnectionProfile,
        message: String,
        now: Date = Date()
    ) -> WidgetMonitorSnapshot {
        WidgetMonitorSnapshot(
            id: "ssh-failure:\(profile.id)",
            displayName: profile.name,
            kind: profile.kind == .sftp ? .sftp : .host,
            state: .down,
            lastCheckedAt: now,
            lastChangedAt: now,
            summary: "Connection failed",
            detail: message,
            openURL: "agent-ssh://monitoring/\(profile.id)"
        )
    }

    private static func sshSummary(status: TerminalConnectionStatus, kind: ConnectionKind) -> String {
        switch status {
        case .connected:
            return kind == .sftp ? "SFTP connected" : "SSH connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        case .error:
            return "Connection error"
        }
    }
}

private extension WidgetMonitorSnapshot {
    var replacementScope: String? {
        if id.hasPrefix("ssh:") || id.hasPrefix("ssh-failure:") {
            return openURL.map { "ssh:\($0)" }
        }
        return nil
    }

    func isOlder(than other: WidgetMonitorSnapshot) -> Bool {
        freshnessDate < other.freshnessDate
    }

    private var freshnessDate: Date {
        lastCheckedAt ?? lastChangedAt ?? .distantPast
    }
}
