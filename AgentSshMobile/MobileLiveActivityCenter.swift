import ActivityKit
import Foundation
import WidgetKit

@MainActor
final class MobileLiveActivityCenter {
    static let shared = MobileLiveActivityCenter()

    private let store = LiveActivitySnapshotStore()
    private var changeObserver: NSObjectProtocol?
    private var removalObserver: NSObjectProtocol?
    private var activitiesBySnapshotId: [String: Activity<MidnightSSHOperationActivityAttributes>] = [:]

    private init() {}

    func start() {
        guard changeObserver == nil else { return }

        changeObserver = NotificationCenter.default.addObserver(
            forName: .backgroundSSHOperationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let operation = notification.object as? BackgroundSSHOperationRecord else { return }
            Task { @MainActor in
                self?.publish(.backgroundOperation(operation))
            }
        }

        removalObserver = NotificationCenter.default.addObserver(
            forName: .backgroundSSHOperationWasRemoved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.object as? String else { return }
            Task { @MainActor in
                self?.remove(snapshotId: "background:\(id)")
            }
        }

        republishPendingBackgroundOperations()
    }

    func publish(_ snapshot: LiveActivitySnapshot) {
        try? store.upsert(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.iOSWidgetKind)

        if snapshot.state.isActive {
            startOrUpdateActivity(for: snapshot)
        } else {
            endActivity(for: snapshot)
        }
    }

    func remove(snapshotId: String) {
        try? store.remove(id: snapshotId)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotConfiguration.iOSWidgetKind)
        if let activity = activitiesBySnapshotId.removeValue(forKey: snapshotId)
            ?? Activity<MidnightSSHOperationActivityAttributes>.activities.first(where: { $0.attributes.snapshotId == snapshotId }) {
            Task {
                await activity.end(nil, dismissalPolicy: .default)
            }
        }
    }

    private func republishPendingBackgroundOperations() {
        guard let data = try? BackgroundSSHOperationStore().load() else { return }
        for operation in data.operations where !operation.status.isTerminal {
            publish(.backgroundOperation(operation))
        }
    }

    private func startOrUpdateActivity(for snapshot: LiveActivitySnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let content = ActivityContent(
            state: MidnightSSHOperationActivityAttributes.ContentState(snapshot: snapshot),
            staleDate: Date().addingTimeInterval(30 * 60)
        )

        if let activity = activitiesBySnapshotId[snapshot.id]
            ?? Activity<MidnightSSHOperationActivityAttributes>.activities.first(where: { $0.attributes.snapshotId == snapshot.id }) {
            activitiesBySnapshotId[snapshot.id] = activity
            Task {
                await activity.update(content)
            }
            return
        }

        do {
            let activity = try Activity.request(
                attributes: MidnightSSHOperationActivityAttributes(snapshot: snapshot),
                content: content,
                pushType: nil
            )
            activitiesBySnapshotId[snapshot.id] = activity
        } catch {
            MobileActivityLogStore.shared.record(
                title: "Live Activity unavailable",
                detail: error.localizedDescription,
                profileId: snapshot.profileId,
                connectionId: snapshot.connectionId,
                systemImage: "rectangle.stack.badge.play",
                severity: .warning
            )
        }
    }

    private func endActivity(for snapshot: LiveActivitySnapshot) {
        guard let activity = activitiesBySnapshotId.removeValue(forKey: snapshot.id)
            ?? Activity<MidnightSSHOperationActivityAttributes>.activities.first(where: { $0.attributes.snapshotId == snapshot.id }) else {
            return
        }

        let content = ActivityContent(
            state: MidnightSSHOperationActivityAttributes.ContentState(snapshot: snapshot),
            staleDate: nil
        )
        Task {
            await activity.end(content, dismissalPolicy: .default)
        }
    }
}
