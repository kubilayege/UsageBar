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
}
