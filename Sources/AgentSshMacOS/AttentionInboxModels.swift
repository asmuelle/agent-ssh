import Foundation

// MARK: - Tier

/// How urgently one finding needs the user, on a single shared ramp for
/// every source (monitor thresholds, Server Doctor, Security Patch Monitor,
/// journal intelligence, SSH hardening advice, connection state).
///
/// The tier is the product's promise to an inexperienced admin: it always
/// answers "do I have to deal with this right now?" in plain language, so
/// each case maps to a phrase rather than a technical severity word.
public enum AttentionTier: String, Codable, CaseIterable, Comparable, Sendable {
    /// FYI — worth knowing, needs nothing.
    case fyi
    /// Should be handled soon, but nothing is on fire.
    case fixThisWeek = "fix-this-week"
    /// The app cannot judge this alone; the user has to look. Ambiguous
    /// input (an `unknown` severity, conflicting evidence) always lands
    /// here — never silently in FYI.
    case needsDecision = "needs-decision"
    /// Something is actively wrong or actively exploited.
    case actNow = "act-now"

    public static func < (lhs: AttentionTier, rhs: AttentionTier) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .actNow: return 3
        case .needsDecision: return 2
        case .fixThisWeek: return 1
        case .fyi: return 0
        }
    }

    public var displayName: String {
        switch self {
        case .actNow: return "Act now"
        case .needsDecision: return "Needs your decision"
        case .fixThisWeek: return "Fix this week"
        case .fyi: return "FYI"
        }
    }
}

// MARK: - Source kind

/// Which subsystem produced an attention item. Drives the confirmation
/// delay before an item may surface: flappy signals must persist before
/// the inbox is allowed to be loud, while completed scans are trusted
/// immediately. Delays adopted from `AgentTriageStore`'s proven values.
public enum AttentionSourceKind: String, Codable, CaseIterable, Sendable {
    /// Tab / host connection state. Binary, not flappy.
    case connection
    /// CPU / memory / disk threshold crossings. Flappy.
    case metric
    /// UFW exposure, monitor errors, unsupported OS. Slow-moving.
    case advisory
    /// A Server Doctor finding — the result of a completed scan.
    case serverDoctor = "server-doctor"
    /// A Security Patch Monitor finding (incl. CISA KEV escalations).
    case securityPatch = "security-patch"
    /// Weak SSH algorithm advice from the host's algorithm inventory.
    case sshAlgorithm = "ssh-algorithm"
    /// Journal issue groups (fingerprinted recurring errors).
    case journal

    /// Seconds an item must persist before it may surface.
    public var confirmationDelay: TimeInterval {
        switch self {
        case .connection, .serverDoctor, .securityPatch, .sshAlgorithm:
            return 0
        case .metric:
            return 12
        case .advisory, .journal:
            return 5
        }
    }
}

// MARK: - Item

/// One thing that needs the user's attention, with the full guidance
/// payload an inexperienced admin needs to act on it safely. The schema
/// follows `ServerDoctorFinding` (the richest guidance model in the app),
/// flattened so every source can populate it without doctor-specific types.
///
/// Identity is `profileId:sourceKind:sourceId` — profile-keyed (not
/// tab-keyed) so items survive disconnects and app restarts, matching the
/// fleet-health stores rather than the in-memory triage store.
public struct AttentionItem: Codable, Equatable, Identifiable, Sendable {
    public var profileId: String
    public var sourceKind: AttentionSourceKind
    /// Stable per-cause identifier within (profile, source), e.g. `cpu`,
    /// `disk:/var`, or a journal fingerprint template hash. Reusing the
    /// same id across observations is what makes `firstSeen` meaningful.
    public var sourceId: String
    public var hostName: String
    public var tier: AttentionTier
    public var title: String
    public var detail: String
    /// Beginner explanation: why this matters and what happens if ignored.
    public var whyItMatters: String
    /// Plain-language, read-only-first suggestions.
    public var safeNextSteps: [String]
    /// Things a beginner might reach for that would make it worse.
    public var avoid: [String]
    /// Raw evidence lines or evidence ids backing the finding.
    public var evidence: [String]
    /// When this cause first appeared. Preserved across re-ingestion so
    /// hysteresis and "since …" narration work.
    public var firstSeen: Date
    /// When the producing source last confirmed the cause still exists.
    public var lastObserved: Date

    public var id: String { "\(profileId):\(sourceKind.rawValue):\(sourceId)" }

    public init(
        profileId: String,
        sourceKind: AttentionSourceKind,
        sourceId: String,
        hostName: String,
        tier: AttentionTier,
        title: String,
        detail: String,
        whyItMatters: String = "",
        safeNextSteps: [String] = [],
        avoid: [String] = [],
        evidence: [String] = [],
        firstSeen: Date = Date(),
        lastObserved: Date = Date()
    ) {
        self.profileId = profileId
        self.sourceKind = sourceKind
        self.sourceId = sourceId
        self.hostName = hostName
        self.tier = tier
        self.title = title
        self.detail = detail
        self.whyItMatters = whyItMatters
        self.safeNextSteps = safeNextSteps
        self.avoid = avoid
        self.evidence = evidence
        self.firstSeen = firstSeen
        self.lastObserved = lastObserved
    }

    /// Whether the item has persisted long enough to surface.
    public func isConfirmed(now: Date) -> Bool {
        now.timeIntervalSince(firstSeen) >= sourceKind.confirmationDelay
    }

    /// Honest staleness for items about hosts nobody is connected to,
    /// on the same contract as `FleetHostHealthRecord`.
    public func freshness(
        now: Date = Date(),
        staleAfter: TimeInterval = 5 * 60
    ) -> FleetObservationFreshness {
        now.timeIntervalSince(lastObserved) > staleAfter ? .stale : .fresh
    }
}

// MARK: - Severity mapping

/// The cross-source severity rank the sidebar's consolidated badge
/// currently duplicates as private extensions in `SidebarView`. It lives
/// here so the inbox and the sidebar rank findings on one scale; the
/// sidebar switches to these when the inbox UI wiring lands.
///
/// Tier mapping rationale: `critical` is reserved by both producers for
/// actively-broken or actively-exploited findings (CISA KEV matches
/// escalate to critical), so it alone maps to "Act now". `high` and
/// `warning` are real but not on fire. `unknown` means the scan could not
/// judge — that is the user's call, never silently FYI.
public extension ServerDoctorSeverity {
    var attentionRank: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .warning: return 2
        case .info: return 1
        case .unknown: return 0
        }
    }

    var attentionTier: AttentionTier {
        switch self {
        case .critical: return .actNow
        case .high, .warning: return .fixThisWeek
        case .info: return .fyi
        case .unknown: return .needsDecision
        }
    }
}

public extension SecurityPatchSeverity {
    var attentionRank: Int {
        switch self {
        case .critical: return 4
        case .high: return 3
        case .warning: return 2
        case .info: return 1
        case .unknown: return 0
        }
    }

    var attentionTier: AttentionTier {
        switch self {
        case .critical: return .actNow
        case .high, .warning: return .fixThisWeek
        case .info: return .fyi
        case .unknown: return .needsDecision
        }
    }
}
