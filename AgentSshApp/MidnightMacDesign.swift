import AppKit
import AgentSshMacOS
import SwiftUI

enum MidnightMacDesign {
    enum FontToken {
        static let title = Font.system(size: 17, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let callout = Font.system(size: 12, weight: .regular)
        static let subheadline = Font.system(size: 11, weight: .regular)
        static let label = Font.system(size: 11, weight: .semibold)
        static let caption = Font.system(size: 10, weight: .regular)
        static let metadataMono = Font.system(size: 10, design: .monospaced)
    }

    enum Radius {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    enum Spacing {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let xlarge: CGFloat = 16
    }

    enum ColorToken {
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
        static let textBackground = Color(nsColor: .textBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let secondaryText = Color(nsColor: .secondaryLabelColor)
        static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        static let selection = Color(nsColor: .selectedContentBackgroundColor)
        static let inactiveSelection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    /// The app's one status palette (DESIGN.md, "Status indicators").
    /// Every state shown in color maps to a tone first, so the same meaning
    /// always looks the same: never pick a status color or symbol directly.
    /// Color is never the only cue; pair a tone with text or its symbol.
    enum StatusTone: CaseIterable {
        /// Connected, healthy, succeeded.
        case ok
        /// A notice or informational finding: nothing is wrong.
        case info
        /// Connecting, queued, starting, restarting, in progress.
        case pending
        /// Warning or high severity, degraded, paused, rolled back.
        case warning
        /// Error, failure, critical severity, unhealthy.
        case critical
        /// Disconnected, stopped, disabled, skipped.
        case inactive
        /// Not known yet.
        case unknown

        var color: Color {
            switch self {
            case .ok: return .green
            case .info: return .blue
            case .pending: return .yellow
            case .warning: return .orange
            case .critical: return .red
            case .inactive, .unknown: return ColorToken.secondaryText
            }
        }

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .pending: return "clock.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "exclamationmark.octagon.fill"
            case .inactive: return "minus.circle"
            case .unknown: return "questionmark.circle.fill"
            }
        }

        /// Resource utilization (0…1): fine below 60 %, a warning below
        /// 85 %, critical above.
        static func forUtilization(_ fraction: Double) -> StatusTone {
            if fraction < 0.6 { return .ok }
            if fraction < 0.85 { return .warning }
            return .critical
        }
    }

    /// Bar and meter tint for utilization. Healthy values stay muted so
    /// color is reserved for the exceptional: on a dashboard the one hot
    /// bar should be the only loud one.
    static func utilizationTint(_ fraction: Double) -> Color {
        let tone = StatusTone.forUtilization(fraction)
        return tone == .ok ? tone.color.opacity(0.55) : tone.color
    }

    static func statusTone(_ status: TerminalConnectionStatus) -> StatusTone {
        switch status {
        case .connected: return .ok
        case .connecting: return .pending
        case .disconnected: return .inactive
        case .error: return .critical
        }
    }

    static func statusColor(_ status: TerminalConnectionStatus) -> Color {
        statusTone(status).color
    }

    static func statusSymbol(_ status: TerminalConnectionStatus) -> String {
        statusTone(status).symbol
    }
}

// MARK: - Domain states → tones
//
// Shared models map to the palette here, once, so every view that shows
// a severity agrees. "high" and "warning" share a tone; the views label
// the difference in text, which DESIGN.md requires anyway.

extension SecurityPatchSeverity {
    var tone: MidnightMacDesign.StatusTone {
        switch self {
        case .critical: return .critical
        case .high, .warning: return .warning
        case .info: return .info
        case .unknown: return .unknown
        }
    }
}

extension ServerDoctorSeverity {
    var tone: MidnightMacDesign.StatusTone {
        switch self {
        case .critical: return .critical
        case .high, .warning: return .warning
        case .info: return .info
        case .unknown: return .unknown
        }
    }
}

extension View {
    func midnightMacCard(radius: CGFloat = MidnightMacDesign.Radius.medium) -> some View {
        background(MidnightMacDesign.ColorToken.controlBackground, in: RoundedRectangle(cornerRadius: radius))
    }

    func midnightMacFocusRing(_ isFocused: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: MidnightMacDesign.Radius.small)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 1)
        )
    }
}
