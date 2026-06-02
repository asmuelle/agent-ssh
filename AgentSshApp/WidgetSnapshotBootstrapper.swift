import Foundation
import OSLog

enum WidgetSnapshotBootstrapper {
    private static let logger = Logger(subsystem: "com.mc-ssh", category: "widget-snapshots")

    static func seedPlaceholderSnapshotIfNeeded() {
        WidgetMonitoringSnapshotCenter.shared.bootstrap()
        logger.info("Widget monitoring snapshot bootstrap requested")
    }
}
