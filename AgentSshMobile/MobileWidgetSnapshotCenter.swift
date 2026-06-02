import Foundation
import WidgetKit

@MainActor
final class MobileWidgetSnapshotCenter {
    static let shared = MobileWidgetSnapshotCenter()

    private let store = WidgetSnapshotStore()

    private init() {}

    func publish(
        profile: MobileConnectionProfile,
        status: MobileSessionStatus,
        connectionId: String? = nil,
        detail: String? = nil
    ) {
        let snapshot = WidgetMonitorSnapshot(
            id: "mobile-ssh:\(profile.id)",
            displayName: profile.name,
            kind: profile.kind == .sftp ? .sftp : .host,
            state: status.widgetState,
            lastCheckedAt: status == .connecting ? nil : Date(),
            lastChangedAt: Date(),
            summary: status.widgetSummary(kind: profile.kind),
            detail: detail ?? status.failureMessage,
            openURL: "agent-ssh://monitoring/\(profile.id)"
        )

        do {
            var file = try store.loadSnapshotFile() ?? WidgetMonitorSnapshotFile(snapshots: [])
            file.snapshots.removeAll { $0.id == WidgetMonitorSnapshot.placeholder().id }
            if let index = file.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                file.snapshots[index] = snapshot
            } else {
                file.snapshots.append(snapshot)
            }
            file.generatedAt = Date()
            try store.save(file)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.iOSWidgetKind)
        } catch {
            MobileActivityLogStore.shared.record(
                title: "Widget update failed",
                detail: error.localizedDescription,
                profileId: profile.id,
                connectionId: connectionId,
                systemImage: "rectangle.stack.badge.exclamationmark",
                severity: .warning
            )
        }
    }
}

private extension MobileSessionStatus {
    var widgetState: WidgetMonitorState {
        switch self {
        case .connected:
            return .up
        case .connecting:
            return .unknown
        case .disconnected:
            return .paused
        case .failed:
            return .down
        }
    }

    func widgetSummary(kind: MobileConnectionKind) -> String {
        switch self {
        case .connected:
            return kind == .sftp ? "SFTP connected" : "SSH connected"
        case .connecting:
            return "Connecting"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Connection failed"
        }
    }
}
