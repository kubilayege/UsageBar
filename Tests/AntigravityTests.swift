import Foundation

struct AntigravityTests {
    private func model(_ label: String, _ remaining: Double?, reset: String = "2026-11-26T17:31:26Z") -> [String: Any] {
        var quota: [String: Any] = ["resetTime": reset]
        if let remaining { quota["remainingFraction"] = remaining }
        return ["label": label, "quotaInfo": quota]
    }

    /// Shape of GetUserStatus from Antigravity 2.x: one config per model and thinking level.
    func testThinkingLevelsFoldIntoOneRowPerModel() throws {
        let configs: [[String: Any]] = [
            model("Gemini 4 Neon (High)", 1), model("Gemini 4 Neon (XHigh)", 1),
            model("Gemini 4 Neon (Medium)", 1), model("Gemini 4 Neon (Low)", 1),
            model("Gemini 4 Carbon (Medium)", 1), model("Gemini 4 Carbon (High)", 1),
            model("Gemini 4 Argon (Medium)", 1),
            model("Orchestrator (Neon)", 1),
            // Proto3 JSON omits a zero remainingFraction: Flash is exhausted.
            model("Gemini 3.8 Flash (High)", nil, reset: "2026-11-26T16:00:00Z"),
            model("Gemini 3.8 Flash (Low)", nil, reset: "2026-11-26T16:00:00Z"),
            model("Claude Opus 5.5 (Low)", 0.6), model("Claude Opus 5.5 (High)", 0.75),
        ]
        let json: JSON = ["userStatus": ["cascadeModelConfigData": [
            "clientModelConfigs": configs,
            "groupedModels": [
                "gemini-4-neon": ["displayName": "Gemini 4 Neon"],
                "gemini-4-carbon": ["displayName": "Gemini 4 Carbon"],
                "claude-opus-5-5": ["displayName": "Claude Opus 5.5"],
            ],
        ]]]
        let windows = AntigravityProvider.windows(from: json)
        XCTAssertEqual(windows.map(\.label), [
            "Gemini 4 Neon", "Gemini 4 Carbon", "Gemini 4 Argon", "Orchestrator (Neon)", "Gemini 3.8 Flash", "Claude Opus 5.5",
        ])
        XCTAssertEqual(windows.map(\.percent).map { $0.rounded() }, [0, 0, 0, 0, 100, 40])
        // The most used models are primary; the rest tie at 0% and keep Antigravity's order.
        XCTAssertEqual(windows.filter(\.isPrimary).map(\.label), ["Gemini 4 Neon", "Gemini 3.8 Flash", "Claude Opus 5.5"])
        XCTAssertEqual(windows.first { $0.label == "Gemini 3.8 Flash" }?.resetsAt, Format.parseISO("2026-11-26T16:00:00Z"))
    }

    /// Shape of RetrieveUserQuotaSummary from Antigravity 2.35.
    func testQuotaSummaryShowsEachGroupsWindows() {
        let json: JSON = ["response": ["groups": [
            ["displayName": "Gemini Models", "buckets": [
                ["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.75, "resetTime": "2026-12-03T12:59:14Z"],
                ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.4, "resetTime": "2026-11-26T17:59:14Z"],
            ]],
            // Unused buckets carry no resetTime; an exhausted one has no remainingFraction.
            ["displayName": "Claude and GPT models", "buckets": [
                ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1],
                ["bucketId": "3p-5h", "window": "5h", "resetTime": "2026-11-26T16:00:00Z"],
            ]],
        ]]]
        let windows = AntigravityProvider.summaryWindows(from: json)
        XCTAssertEqual(windows.map(\.label), ["Gemini 7d", "Gemini 5h", "Claude 7d", "Claude 5h"])
        XCTAssertEqual(windows.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        XCTAssertEqual(windows.map { $0.percent.rounded() }, [25, 60, 0, 100])
        let week: TimeInterval = 7 * 86400, fiveHours: TimeInterval = 5 * 3600
        XCTAssertEqual(windows.map(\.windowDuration), [week, fiveHours, week, fiveHours])
        XCTAssertTrue(windows.allSatisfy(\.isPrimary))
        XCTAssertEqual(windows[2].resetsAt, nil)
        XCTAssertEqual(windows[3].resetsAt, Format.parseISO("2026-11-26T16:00:00Z"))
        XCTAssertEqual(AntigravityProvider.summaryWindows(from: [:]).count, 0)
    }
}
