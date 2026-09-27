import Foundation

extension UsageWindow {
    /// Projections this early in a window are mostly noise, so none are made before it.
    static let minimumProjectionFraction = 0.1

    /// Projected usage at reset, once enough of the window has passed to extrapolate.
    func projection(now: Date = Date()) -> Double? {
        guard let elapsed = elapsedFraction(now: now), elapsed >= Self.minimumProjectionFraction else { return nil }
        return projectedPercent(now: now)
    }

    /// When the current burn rate reaches 100%, if that happens before the window resets.
    func exhaustion(now: Date = Date()) -> Date? {
        guard hasLimit, percent > 0, percent < 100, let resetsAt, let duration = windowDuration,
              let elapsed = elapsedFraction(now: now), elapsed >= Self.minimumProjectionFraction else { return nil }
        let secondsLeft = (100 - percent) / percent * elapsed * duration
        let date = now.addingTimeInterval(secondsLeft)
        return date < resetsAt ? date : nil
    }
}

/// The answer to "when do I get cut off?", ranked across every tracked limit.
struct Runway: Equatable {
    enum Kind: Int, Comparable {
        case blocked, runsOut, clear
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// One account's latest numbers. `title` names it in sentences: "Codex" or "Codex · work".
    struct Source {
        var id: String
        var title: String
        var snapshot: UsageSnapshot
    }

    struct Item: Equatable, Identifiable {
        var provider: ProviderID
        var source: String
        var title: String
        var window: UsageWindow
        var kind: Kind
        /// Blocked: until reset. Runs out: until exhaustion. Clear: until reset.
        var remaining: TimeInterval?
        /// Runs out only: time between exhaustion and reset.
        var gap: TimeInterval?
        var projected: Double?
        var id: String { source + "/" + window.id }
        var name: String { "\(title) \(window.label)" }
    }

    var items: [Item]
    var lead: Item? { items.first }
    var alerts: [Item] { items.filter { $0.kind != .clear } }

    init(_ snapshots: [(ProviderID, UsageSnapshot)], now: Date = Date()) {
        self.init(sources: snapshots.map { Source(id: $0.0.rawValue, title: $0.0.displayName, snapshot: $0.1) }, now: now)
    }

    init(sources: [Source], now: Date = Date()) {
        var items: [Item] = []
        for source in sources {
            let snap = source.snapshot
            func item(_ w: UsageWindow, _ kind: Kind, _ remaining: TimeInterval?, gap: TimeInterval? = nil, projected: Double? = nil) -> Item {
                Item(provider: snap.provider, source: source.id, title: source.title, window: w, kind: kind,
                     remaining: remaining, gap: gap, projected: projected)
            }
            for w in snap.primaryWindows where w.hasLimit {
                let untilReset = w.resetsAt.map { max(0, $0.timeIntervalSince(now)) }
                if w.percent >= 100 {
                    items.append(item(w, .blocked, untilReset))
                } else if let out = w.exhaustion(now: now) {
                    let left = max(0, out.timeIntervalSince(now))
                    items.append(item(w, .runsOut, left, gap: untilReset.map { max(0, $0 - left) }, projected: w.projection(now: now)))
                } else if let projected = w.projection(now: now) {
                    items.append(item(w, .clear, untilReset, projected: projected))
                }
            }
        }
        self.items = items.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            switch a.kind {
            // The longest wait is the real constraint; the soonest run-out is the most urgent.
            case .blocked: return (a.remaining ?? .infinity) > (b.remaining ?? .infinity)
            case .runsOut: return (a.remaining ?? .infinity) < (b.remaining ?? .infinity)
            case .clear: return (a.projected ?? 0) > (b.projected ?? 0)
            }
        }
    }
}
