import Foundation

struct WorkLogTests {
    private func write(_ records: [JSON], name: String = UUID().uuidString + ".jsonl", in dir: URL? = nil) throws -> URL {
        let folder = dir ?? FileManager.default.temporaryDirectory
        let url = folder.appendingPathComponent(name)
        try records.map { try JSONSerialization.data(withJSONObject: $0, options: .withoutEscapingSlashes) }.reduce(into: Data()) { $0.append($1); $0.append(10) }.write(to: url)
        return url
    }

    func testActiveTimeJoinsShortGapsAndCountsOverlapOnce() {
        XCTAssertEqual(WorkReceipt.activeMinutes([], idle: 15), 0)
        XCTAssertEqual(WorkReceipt.activeMinutes([100], idle: 15), 1)
        // 100→110 is continuous (11), 110→200 is idle (+1), 200→205 continuous (+5).
        XCTAssertEqual(WorkReceipt.activeMinutes([100, 110, 200, 205], idle: 15), 17)

        let base = Int(Date().timeIntervalSince1970 / 60)
        let day = Format.dayKey(Date(timeIntervalSince1970: Double(base) * 60))
        func session(_ id: String, _ minutes: [Int], project: String = "/work/app") -> WorkSession {
            WorkSession(id: id, provider: .claude, cwd: project, title: id, branch: nil,
                        days: [day: WorkDay(minutes: minutes.map { base + $0 })], project: project)
        }
        let range = WorkRange(.day, containing: Date(timeIntervalSince1970: Double(base) * 60))
        let r = WorkReceipt.build([session("a", [0, 5, 10]), session("b", [5, 10]), session("c", [0, 3], project: "/work/other")],
                                  range: range, hidden: [], idleMinutes: 15)
        XCTAssertEqual(r.projects.count, 2)
        XCTAssertEqual(r.projects.first?.name, "app")
        XCTAssertEqual(r.projects.first?.activeMinutes, 11)
        XCTAssertEqual(r.activeMinutes, 11)
        XCTAssertEqual(r.sessionCount, 3)
        let hidden = WorkReceipt.build([session("a", [0]), session("c", [0], project: "/work/other")], range: range, hidden: ["/work/other"])
        XCTAssertEqual(hidden.projects.map(\.name), ["app"])
        XCTAssertEqual(hidden.hiddenProjects, ["/work/other"])
    }

    func testClaudeTitlesEditsAndSubagentsMerge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func assistant(_ ts: String, session: String, tool: String?, file: String) -> JSON {
            var content: [JSON] = [["type": "text", "text": "\"type\":\"user\" in text is not metadata"]]
            if let tool { content.append(["type": "tool_use", "id": UUID().uuidString, "name": tool, "input": ["file_path": file]]) }
            return ["parentUuid": NSNull(), "message": ["id": UUID().uuidString, "model": "claude-test", "role": "assistant", "content": content,
                                                        "usage": ["input_tokens": 10, "output_tokens": 5]],
                    "type": "assistant", "timestamp": ts, "cwd": "/work/app", "sessionId": session, "gitBranch": "main"]
        }
        let main = try write([
            ["type": "user", "message": ["role": "user", "content": "secret prompt"], "timestamp": "2026-09-15T09:00:10Z", "cwd": "/work/app", "sessionId": "s1"],
            assistant("2026-09-15T09:02:00Z", session: "s1", tool: "Edit", file: "/work/app/Sources/App.swift"),
            assistant("2026-09-15T09:03:00Z", session: "s1", tool: "Read", file: "/work/app/README.md"),
            assistant("2026-09-15T09:04:00Z", session: "s1", tool: "Write", file: "/Users/someone/elsewhere/notes.md"),
            ["type": "ai-title", "aiTitle": "Add the\nwork log", "sessionId": "s1"],
        ], name: "s1.jsonl", in: dir)
        let sub = try write([assistant("2026-09-15T09:05:00Z", session: "s1", tool: "Edit", file: "/work/app/Sources/App.swift")],
                            name: "agent-x.jsonl", in: dir)
        let merged = WorkLogScanner.merge(WorkLogScanner.parseClaude(main.path) + WorkLogScanner.parseClaude(sub.path))
        XCTAssertEqual(merged.count, 1)
        guard let s = merged.first, let day = s.days.values.first else { return XCTAssertTrue(false) }
        XCTAssertEqual(s.title, "Add the work log")
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(day.files, ["Sources/App.swift": 2, "notes.md": 1])
        XCTAssertEqual(day.minutes.count, 5)
        XCTAssertEqual(day.usage["claude-test"]?.turns, 4)
        XCTAssertEqual(day.usage["claude-test"]?.tokens, 60)
        // Only numbers, names and titles are cached, never message text.
        let cached = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
        XCTAssertTrue(!cached.contains("secret prompt"))
    }

    func testCodexPatchesAndSubagentParent() throws {
        XCTAssertEqual(WorkLogScanner.patchedFiles("*** Begin Patch\n*** Update File: src/a.ts\n@@\n*** Add File: /w/b.ts\n*** End Patch"), ["src/a.ts", "/w/b.ts"])
        // Patches embedded in a JavaScript string keep their escapes.
        XCTAssertEqual(WorkLogScanner.patchedFiles(#"const p = "*** Begin Patch\n*** Delete File: /w/c.json\n*** Move to: d.json\n""#), ["/w/c.json", "d.json"])
        let url = try write([
            ["timestamp": "2026-09-15T10:00:00Z", "type": "session_meta", "payload": ["id": "child", "session_id": "parent", "cwd": "/w", "git": ["branch": "dev"]]],
            ["timestamp": "2026-09-15T10:03:00Z", "type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch",
                                                                                      "input": "*** Begin Patch\n*** Update File: /w/src/a.ts\n*** End Patch"]],
            ["timestamp": "2026-09-15T10:04:00Z", "type": "compacted", "payload": ["message": "*** Begin Patch\n*** Update File: /w/old.ts"]],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let sessions = WorkLogScanner.parseCodex(url.path)
        XCTAssertEqual(sessions.first?.id, "codex/parent")
        XCTAssertEqual(sessions.first?.branch, "dev")
        XCTAssertEqual(sessions.first?.days.values.first?.files, ["src/a.ts": 1])
        XCTAssertEqual(WorkLogScanner.merge(sessions, codexTitles: ["parent": "Fix the build"]).first?.title, "Fix the build")
    }

    func testT3TitleRunsFoldIntoTheirThread() throws {
        let tmp = "/private/var/folders/x/T/t3code-claude-title-"
        func log(_ id: String, cwd: String, at ts: String, prompt: String = "work", title: String? = nil) throws -> URL {
            var records: [JSON] = [
                ["type": "user", "message": ["role": "user", "content": prompt], "timestamp": ts, "cwd": cwd, "sessionId": id],
                ["type": "assistant", "message": ["id": id, "model": "claude-haiku", "role": "assistant", "content": [["type": "text", "text": "{}"]],
                                                  "usage": ["input_tokens": 100, "output_tokens": 10]],
                 "timestamp": ts, "cwd": cwd, "sessionId": id],
            ]
            if let title { records.append(["type": "ai-title", "aiTitle": title, "sessionId": id]) }
            return try write(records)
        }
        let urls = [
            try log("thread", cwd: "/work/game", at: "2026-09-15T08:05:01.9Z"),
            try log("other", cwd: "/work/site", at: "2026-09-15T08:06:30Z"),
            try log("name", cwd: tmp + "51kL71", at: "2026-09-15T08:04:59.3Z", prompt: "Generate a title…\n\nUser message:\nfix links", title: "Hidden link visibility"),
            try log("rename", cwd: tmp + "Ab12Cd", at: "2026-09-15T09:30:00Z",
                    prompt: "Regenerate the title for an existing T3 Code thread.\nThe previous title was \"Hidden link visibility\".\nReturn JSON", title: "Link materials"),
            try log("orphan", cwd: tmp + "Zz99Yy", at: "2026-09-15T12:00:00Z", title: "Nothing"),
        ]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let parsed = urls.flatMap { WorkLogScanner.parseClaude($0.path) }
        XCTAssertEqual(parsed.first { $0.id == "claude/rename" }?.previousTitle, "Hidden link visibility")
        let merged = WorkLogScanner.merge(parsed)
        XCTAssertEqual(Set(merged.map(\.id)), ["claude/thread", "claude/other"])
        let thread = merged.first { $0.id == "claude/thread" }
        XCTAssertEqual(thread?.project, "/work/game")
        XCTAssertEqual(thread?.days.values.first?.usage["claude-haiku"]?.turns, 3)
        XCTAssertEqual(merged.first { $0.id == "claude/other" }?.days.values.first?.usage["claude-haiku"]?.turns, 1)
    }

    func testExportsAndRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        let date = Format.day(from: "2026-09-16")!
        let week = WorkRange(.week, containing: date, calendar: calendar)
        XCTAssertEqual(week.dayKeys.first, "2026-09-14")
        XCTAssertEqual(week.dayKeys.count, 7)
        XCTAssertEqual(week.shifted(by: 1, calendar: calendar).dayKeys.first, "2026-09-21")
        XCTAssertEqual(WorkRange(.month, containing: date).dayKeys.count, 30)
        XCTAssertEqual(Format.hm(252), "4h 12m")
        XCTAssertEqual(Format.hm(35), "35m")

        let start = Int(date.addingTimeInterval(9 * 3600).timeIntervalSince1970 / 60)
        let usage = WorkUsage(turns: 2, input: 1_000_000, output: 100_000)
        let sessions = [
            WorkSession(id: "claude/1", provider: .claude, cwd: "/w/app", title: "Ship, the \"log\"", branch: "main",
                        days: ["2026-09-16": WorkDay(minutes: Array(start...(start + 30)), files: ["Sources/A.swift": 2, "B.swift": 1], usage: ["m": usage])],
                        project: "/w/app"),
            WorkSession(id: "codex/2", provider: .codex, cwd: "/w/app", title: nil, branch: nil,
                        days: ["2026-09-16": WorkDay(minutes: [start + 60], files: ["C.swift": 1])], project: "/w/app"),
        ]
        let r = WorkReceipt.build(sessions, range: WorkRange(.day, containing: date), idleMinutes: 15) { _, _, u in Double(u.tokens) / 1_000_000 }
        XCTAssertEqual(r.activeMinutes, 32)
        XCTAssertEqual(r.fileCount, 3)
        XCTAssertEqual(r.cost, 1.1)
        XCTAssertEqual(r.projects.first?.sessions.last?.name, "Edited C.swift")

        let text = WorkReceiptExport.render(r, as: .text, options: WorkExportOptions(files: true, times: true, usage: true))
        XCTAssertTrue(text.hasPrefix("Work log · Wed 16 Sep 2026\n32m active · 1 project · 2 sessions · 3 files changed"))
        XCTAssertTrue(text.contains("  • Ship, the \"log\" (Claude, 09:00–09:31, 31m, 1.1M tok, ≈$1.10)"))
        XCTAssertTrue(text.contains("    A.swift, B.swift"))
        let plain = WorkReceiptExport.render(r, as: .text, options: WorkExportOptions(files: false, times: false, usage: false))
        XCTAssertTrue(!plain.contains("A.swift") && !plain.contains("09:00") && !plain.contains("$"))
        let compact = WorkReceiptExport.render(r, as: .text, options: WorkExportOptions(sessions: false))
        XCTAssertTrue(compact.hasSuffix("\n\napp · 32m"))
        let markdown = WorkReceiptExport.render(r, as: .markdown)
        XCTAssertTrue(markdown.contains("### app · 32m"))
        XCTAssertTrue(markdown.contains("- **Ship, the \"log\"** · Claude · 09:00–09:31 · 31m  \n  `A.swift`, `B.swift`"))
        let csv = WorkReceiptExport.render(r, as: .csv).split(separator: "\n")
        XCTAssertEqual(csv.count, 3)
        XCTAssertTrue(csv[1].hasPrefix("2026-09-16,app,\"Ship, the \"\"log\"\"\",Claude,m,09:00,09:31,31,0.52,Sources/A.swift; B.swift,1100000,1.1000"))
        let other = WorkReceipt.build(sessions + [WorkSession(id: "claude/3", provider: .claude, cwd: "/w/site", title: "Hero", branch: nil,
                                                              days: ["2026-09-16": WorkDay(minutes: [start + 120])], project: "/w/site")],
                                      range: WorkRange(.day, containing: date), idleMinutes: 15)
        let trimmed = other.without(projects: ["/w/site"])
        XCTAssertEqual(trimmed.projects.map(\.id), ["/w/app"])
        XCTAssertEqual(trimmed.activeMinutes, 32)
        XCTAssertEqual(trimmed.sessionCount, 2)
        let one = WorkReceiptExport.render(r.only(session: r.projects[0].sessions[1]), as: .text, scope: .session)
        XCTAssertEqual(one, "Edited C.swift (app, Codex, 10:00–10:01, 1m)\n  C.swift")
    }
}
