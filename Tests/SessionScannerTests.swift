import Foundation

struct SessionScannerTests {
    func testClaudeReadsJSONAndKeepsRealModelAfterSyntheticMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-Users-test-project-with-dashes")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cwd = "/Users/test/Project \"quoted\"/with-dashes"
        let real: [String: Any] = ["type": "assistant", "sessionId": "session-one", "cwd": cwd,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "gitBranch": "main",
            "message": ["model": "claude-opus-4-1", "usage": ["input_tokens": 20, "cache_read_input_tokens": 300, "cache_creation_input_tokens": 40]]]
        let synthetic: [String: Any] = ["type": "assistant", "sessionId": "session-one", "cwd": cwd,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["model": "<synthetic>", "usage": ["input_tokens": 0]]]
        let lines = try [real, synthetic].map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
        // Valid JSONL may contain whitespace after punctuation.
        try (lines.joined(separator: "\n").replacingOccurrences(of: "\":", with: "\": ") + "\n")
            .write(to: project.appendingPathComponent("session-one.jsonl"), atomically: true, encoding: .utf8)
        let sessions = LiveSessionScanner.claudeSessions(since: Date().addingTimeInterval(-600), processes: [], root: root.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.cwd, cwd)
        XCTAssertEqual(sessions.first?.model, "opus-4-1")
        XCTAssertEqual(sessions.first?.tokens, 360)
    }

    func testClaudeDoesNotTreatTouchedHistoricalLogAsRecentActivity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"cwd\":\"/tmp/project\",\"sessionId\":\"old\",\"timestamp\":\"2020-01-01T00:00:00Z\"}\n"
            .write(to: project.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertTrue(LiveSessionScanner.claudeSessions(since: Date().addingTimeInterval(-600), processes: [], root: root.path).isEmpty)
    }
    func testOnlyMatchingClaudeSessionIsRunningAndIdleSessionIsRetained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-tmp-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        for name in ["older", "other"] {
            let record: JSON = ["type": "user", "sessionId": name, "cwd": "/tmp/project", "timestamp": "2020-01-01T00:00:00Z"]
            try JSONSerialization.data(withJSONObject: record).write(to: project.appendingPathComponent(name + ".jsonl"))
        }
        let processes = [SessionProcess(pid: 123, provider: .claude, sessionID: "older", cwd: "/tmp/project")]
        let sessions = LiveSessionScanner.claudeSessions(since: Date().addingTimeInterval(-600), processes: processes, root: root.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions.first?.id.hasSuffix("older.jsonl") == true)
        XCTAssertEqual(sessions.first?.isProcessRunning, true)
    }

}
