import SwiftUI

// MARK: - Providers

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, codex, cursor, gemini, antigravity, opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        }
    }

    /// Short code shown in the menu bar.
    var shortCode: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        case .cursor: return "Cu"
        case .gemini: return "G"
        case .antigravity: return "AG"
        case .opencode: return "OC"
        }
    }

    /// Small subtitle shown under the name in the filter chips.
    var windowSummary: String {
        switch self {
        case .claude: return "5h · 7d"
        case .codex: return "5h · 7d"
        case .cursor: return "Monthly"
        case .gemini: return "Daily"
        case .antigravity: return "Quota"
        case .opencode: return "Tokens"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(hex: 0x6A9EDB)
        case .codex: return Color(hex: 0x8FBF6A)
        case .cursor: return Color(hex: 0xB07FD6)
        case .gemini: return Color(hex: 0x3DC1B3)
        case .antigravity: return Color(hex: 0xD96FB0)
        case .opencode: return Color(hex: 0xE0C14D)
        }
    }

    var isExperimental: Bool { self == .gemini || self == .antigravity }

    var statusService: StatusService? {
        switch self {
        case .claude: return .claude
        case .codex: return .openai
        case .cursor: return .cursor
        default: return nil
        }
    }

    var howToConfigure: String {
        switch self {
        case .claude: return "Sign in with Claude Code (run `claude` in a terminal)."
        case .codex: return "Sign in with Codex CLI using ChatGPT (run `codex`)."
        case .cursor: return "Sign in to the Cursor app."
        case .gemini: return "Sign in with Gemini CLI (run `gemini`)."
        case .antigravity: return "Launch Antigravity and sign in; usage is read from its local language server."
        case .opencode: return "Use OpenCode at least once; token usage is read from its local database."
        }
    }
}

// MARK: - Severity / Pace

enum Severity: Int, Comparable, Codable, Sendable {
    case ok, caution, warning, critical, limit

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    static func from(percent: Double) -> Severity {
        switch percent {
        case ..<50: return .ok
        case ..<75: return .caution
        case ..<90: return .warning
        case ..<100: return .critical
        default: return .limit
        }
    }

    var label: String {
        switch self {
        case .ok: return "Healthy"
        case .caution: return "Caution"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .limit: return "At Limit"
        }
    }

    var color: Color {
        switch self {
        case .ok: return Theme.ok
        case .caution: return Theme.caution
        case .warning: return Theme.warning
        case .critical, .limit: return Theme.critical
        }
    }
}

enum PaceVerdict: String, Sendable {
    case healthy = "Healthy", risky = "Risky", over = "Over"

    static func from(projected: Double) -> PaceVerdict {
        if projected >= 100 { return .over }
        if projected >= 85 { return .risky }
        return .healthy
    }

    var color: Color {
        switch self {
        case .healthy: return Theme.ok
        case .risky: return Theme.caution
        case .over: return Theme.critical
        }
    }
}

// MARK: - Usage data

struct UsageWindow: Identifiable, Codable, Sendable, Equatable {
    var id: String
    var label: String
    var percent: Double
    var resetsAt: Date?
    /// Total length of the rolling window (used for pace projection).
    var windowDuration: TimeInterval?
    /// Free-form detail such as "$11.79 / $20.00" or "1.2M tokens".
    var detail: String?
    var isPrimary: Bool = true
    /// False for informational windows without a hard cap (e.g. OpenCode token counts).
    var hasLimit: Bool = true

    var severity: Severity { hasLimit ? Severity.from(percent: percent) : .ok }

    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let remaining = max(0, resetsAt.timeIntervalSince(now))
        return min(1, max(0, (windowDuration - remaining) / windowDuration))
    }

    /// Projected usage at the end of the window assuming the current burn rate continues.
    func projectedPercent(now: Date = Date()) -> Double? {
        guard hasLimit, let elapsed = elapsedFraction(now: now) else { return nil }
        // Linear extrapolation from the first bit of usage; clamp the denominator so a
        // freshly reset window doesn't explode to infinity.
        return min(999, percent / max(elapsed, 0.05))
    }

    func paceVerdict(now: Date = Date()) -> PaceVerdict? {
        projectedPercent(now: now).map(PaceVerdict.from)
    }
}

struct ExtraUsage: Codable, Sendable, Equatable {
    var title: String
    var used: Double?
    var limit: Double?
    var utilization: Double?
    var currency: String?

    var detail: String {
        switch (used, limit) {
        case let (u?, l?): return "\(Format.money(u, currency))/\(Format.money(l, currency))"
        case let (u?, nil): return Format.money(u, currency)
        case let (nil, l?): return "limit \(Format.money(l, currency))"
        default: return utilization.map { Format.percent($0) } ?? "enabled"
        }
    }

    var percent: Double? {
        if let utilization { return utilization }
        if let used, let limit, limit > 0 { return used / limit * 100 }
        return nil
    }
}

struct BankedResets: Codable, Sendable, Equatable {
    var available: Int
    var applicable: Int?
}

struct UsageSnapshot: Codable, Sendable, Equatable {
    var provider: ProviderID
    var windows: [UsageWindow]
    var planName: String?
    var accountLabel: String?
    var extraUsage: ExtraUsage?
    var fetchedAt: Date = Date()
    var note: String?
    var bankedResets: BankedResets?

    var primaryWindows: [UsageWindow] { windows.filter(\.isPrimary) }
    var secondaryWindows: [UsageWindow] { windows.filter { !$0.isPrimary } }

    var worstSeverity: Severity {
        windows.filter(\.hasLimit).map(\.severity).max() ?? .ok
    }

    /// The window used for pace projection: the longest limited window.
    var paceWindow: UsageWindow? {
        primaryWindows.filter { $0.hasLimit && $0.windowDuration != nil }
            .max { ($0.windowDuration ?? 0) < ($1.windowDuration ?? 0) }
    }
}

enum ProviderState: Sendable {
    case idle
    case loading(stale: UsageSnapshot?)
    case ready(UsageSnapshot)
    case notConfigured(String)
    case error(String, stale: UsageSnapshot?)
    /// Endpoint asked us to back off; we keep showing the last snapshot until `until`.
    case cooldown(until: Date, stale: UsageSnapshot?)

    var snapshot: UsageSnapshot? {
        switch self {
        case .ready(let s): return s
        case .loading(let s), .error(_, let s), .cooldown(_, let s): return s
        default: return nil
        }
    }

    var cooldownUntil: Date? {
        if case .cooldown(let until, _) = self { return until }
        return nil
    }

    var errorMessage: String? {
        if case .error(let m, _) = self { return m }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

// MARK: - Errors

struct ProviderError: LocalizedError, Sendable {
    enum Kind: Sendable { case notConfigured, auth, network, parse, unavailable, rateLimited }
    let kind: Kind
    let message: String
    /// Seconds to wait before retrying (rate limits).
    var retryAfter: TimeInterval?
    init(_ kind: Kind, _ message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind; self.message = message; self.retryAfter = retryAfter
    }
    var errorDescription: String? { message }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> UsageSnapshot
}

// MARK: - Service status

enum StatusService: String, CaseIterable, Identifiable, Sendable {
    case claude, openai, cursor
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .openai: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var url: URL {
        switch self {
        case .claude: return URL(string: "https://status.claude.com/api/v2/status.json")!
        case .openai: return URL(string: "https://status.openai.com/api/v2/status.json")!
        case .cursor: return URL(string: "https://status.cursor.com/api/v2/status.json")!
        }
    }

    var pageURL: URL {
        switch self {
        case .claude: return URL(string: "https://status.claude.com")!
        case .openai: return URL(string: "https://status.openai.com")!
        case .cursor: return URL(string: "https://status.cursor.com")!
        }
    }
}

struct ServiceStatus: Identifiable, Sendable, Equatable {
    let service: StatusService
    let indicator: String
    let description: String
    var id: String { service.rawValue }

    var isOperational: Bool { indicator == "none" }

    var shortLabel: String {
        switch indicator {
        case "none": return "Operational"
        case "minor": return "Degraded"
        case "major": return "Partial Outage"
        case "critical": return "Major Outage"
        default: return description
        }
    }

    var color: Color {
        switch indicator {
        case "none": return Theme.ok
        case "minor": return Theme.caution
        case "major": return Theme.warning
        case "critical": return Theme.critical
        default: return Theme.textMuted
        }
    }
}

// MARK: - Activity (local logs)

struct DayActivity: Codable, Sendable, Identifiable, Hashable {
    var day: String        // yyyy-MM-dd (local)
    var provider: ProviderID
    var tokens: Int
    var messages: Int
    var cost: Double = 0
    var id: String { "\(provider.rawValue)-\(day)" }
}

struct ActivityData: Sendable {
    var days: [DayActivity]
    var scannedAt: Date
}

// MARK: - History

struct HistoryPoint: Codable, Sendable, Identifiable {
    var t: Date
    var p: ProviderID
    var w: String
    var pct: Double
    var proj: Double?
    var id: String { "\(p.rawValue)-\(w)-\(t.timeIntervalSince1970)" }
}

// MARK: - Menu bar

struct MenuBarSegment: Identifiable {
    var id: String
    var dot: Color
    var text: String
    var color: Color
}

// MARK: - Live sessions

struct LiveSession: Identifiable, Sendable, Equatable {
    var id: String
    var provider: ProviderID
    var project: String
    var cwd: String
    var model: String?
    var branch: String?
    var tokens: Int?
    var tokensLabel: String
    var lastActivity: Date
    var isProcessRunning: Bool

    /// The session log was written to in the last 2 minutes.
    func isLive(now: Date) -> Bool {
        now.timeIntervalSince(lastActivity) < 120
    }
}
