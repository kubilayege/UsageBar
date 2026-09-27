import Foundation

struct RunwayTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ id: String, _ percent: Double, duration: TimeInterval, remaining: TimeInterval) -> UsageWindow {
        UsageWindow(id: id, label: id, percent: percent, resetsAt: now.addingTimeInterval(remaining), windowDuration: duration)
    }

    func testExhaustionOnlyWhenPaceBeatsTheReset() {
        // Half the window used in a fifth of it: runs out at 40% elapsed, long before the reset.
        let fast = window("5h", 50, duration: 5 * 3600, remaining: 4 * 3600)
        XCTAssertEqual(fast.exhaustion(now: now)?.timeIntervalSince(now), 3600)
        // A tenth used in half the window lasts to the reset.
        XCTAssertEqual(window("7d", 10, duration: 7 * 86400, remaining: 3.5 * 86400).exhaustion(now: now), nil)
        // Too early in the window to extrapolate, and nothing to project at 0% or 100%.
        XCTAssertEqual(window("5h", 40, duration: 5 * 3600, remaining: 4.75 * 3600).exhaustion(now: now), nil)
        XCTAssertEqual(window("5h", 40, duration: 5 * 3600, remaining: 4.75 * 3600).projection(now: now), nil)
        XCTAssertEqual(window("5h", 0, duration: 5 * 3600, remaining: 3600).exhaustion(now: now), nil)
        XCTAssertEqual(window("5h", 100, duration: 5 * 3600, remaining: 3600).exhaustion(now: now), nil)
    }

    func testRunwayRanksBlockedThenSoonestRunOutThenClear() {
        func snap(_ id: ProviderID, _ windows: [UsageWindow]) -> (ProviderID, UsageSnapshot) {
            (id, UsageSnapshot(provider: id, windows: windows))
        }
        let runway = Runway([
            snap(.claude, [window("5h", 50, duration: 5 * 3600, remaining: 4 * 3600),     // out in 1h
                           window("7d", 20, duration: 7 * 86400, remaining: 3.5 * 86400)]), // clear, ends near 40%
            snap(.codex, [window("5h", 100, duration: 5 * 3600, remaining: 3600),          // blocked 1h
                          window("7d", 100, duration: 7 * 86400, remaining: 2 * 86400)]),  // blocked 2d: the real constraint
            snap(.cursor, [window("monthly", 80, duration: 30 * 86400, remaining: 15 * 86400)]), // out in 3.75d
        ], now: now)
        XCTAssertEqual(runway.items.map(\.id), ["codex/7d", "codex/5h", "claude/5h", "cursor/monthly", "claude/7d"])
        XCTAssertEqual(runway.lead?.kind, .blocked)
        XCTAssertEqual(runway.lead?.remaining, 2 * 86400)
        XCTAssertEqual(runway.items[2].gap, 3 * 3600)
        XCTAssertEqual(runway.alerts.count, 4)
        XCTAssertEqual(Runway([], now: now).lead, nil)
        XCTAssertEqual(Format.span(2 * 86400 + 3 * 3600), "2d 3h")
        XCTAssertEqual(Format.span(3600 + 60 * 7), "1h 7m")
        XCTAssertEqual(Format.span(30), "<1m")
    }
}
