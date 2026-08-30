import AgentSshMacOS
import SwiftUI

/// How each attention tier looks and reads. Kept in one place so the
/// panel, the sidebar badge and any future surface describe a tier the
/// same way — the tier name is the product's promise to the user, and it
/// must not drift between screens.
extension AttentionTier {
    /// Accent used for fills, bands, icons and strokes, where low
    /// contrast is fine because the shape carries the meaning.
    var color: Color {
        switch self {
        case .actNow: return .red
        case .needsDecision: return .orange
        case .fixThisWeek: return .yellow
        case .fyi: return .secondary
        }
    }

    /// Colour for text *set in* the tier colour. Yellow and orange are
    /// legible on a dark background and disappear on a light one, so the
    /// two warm tiers fall back to the primary label colour rather than
    /// rendering the substance of a finding in something unreadable —
    /// the coloured band, icon and tag chip still carry the tier.
    var textColor: Color {
        switch self {
        case .actNow: return .red
        case .needsDecision, .fixThisWeek, .fyi: return .primary
        }
    }

    var symbol: String {
        switch self {
        case .actNow: return "exclamationmark.octagon.fill"
        case .needsDecision: return "questionmark.circle.fill"
        case .fixThisWeek: return "wrench.and.screwdriver.fill"
        case .fyi: return "info.circle"
        }
    }

    /// Short all-caps tag rendered on a row.
    var tagText: String {
        switch self {
        case .actNow: return "ACT NOW"
        case .needsDecision: return "DECIDE"
        case .fixThisWeek: return "THIS WEEK"
        case .fyi: return "FYI"
        }
    }

    /// One line under a section header saying what the tier means, in the
    /// terms an inexperienced admin actually needs.
    var sectionExplanation: String {
        switch self {
        case .actNow:
            return "Something is broken or actively exploited. Deal with these first."
        case .needsDecision:
            return "We could not judge these for you — a look from you decides what happens."
        case .fixThisWeek:
            return "Real, but nothing is on fire. Worth handling in the next few days."
        case .fyi:
            return "Worth knowing about. No action needed."
        }
    }

    /// Whether the tier is loud enough to reorganize the view around it.
    var isUrgent: Bool { self >= .needsDecision }
}
