import Foundation

/// Uses structured log records for metadata and matches running processes to individual sessions.
enum LiveSessionScanner {
    static let activeWindow: TimeInterval = 10 * 60

    static func scan() -> [LiveSession] {
        let cutoff = Date().addingTimeInterval(-activeWindow)
        let processes = SessionProcess.scan()
        var out = claudeSessions(since: cutoff, processes: processes)
        out += codexSessions(since: cutoff, processes: processes)
        out += openCodeSessions(since: cutoff, running: processes.contains { $0.provider == .opencode })
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    static func claudeSessions(since cutoff: Date, processes: [SessionProcess] = [], root: String = Files.claudeRoot + "/projects") -> [LiveSession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let agents = processes.filter { $0.provider == .claude }
        var out: [LiveSession] = []
        for project in projects {
            let directory = (root as NSString).appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                let path = (directory as NSString).appendingPathComponent(file)
                let sessionID = (file as NSString).deletingPathExtension
                let running = agents.contains { $0.matches(sessionID: sessionID, path: path) }
                guard let modified = modificationDate(path), modified >= cutoff || running else { continue }
                let records = JSONL.edges(path)
                guard let session = claudeSession(records: records, path: path, running: running),
                      session.lastActivity >= cutoff || running else { continue }
                out.append(session)
            }
        }
        // A CLI without a session id can only be associated with its newest recent log in its cwd.
        // Never mark every session of the same provider (or project) as running.
        markNewestRecentSessions(&out, processes: agents, cutoff: cutoff)
        return out
    }

    static func claudeSession(records: [JSON], path: String, running: Bool) -> LiveSession? {
        var cwd: String?, model: String?, branch: String?, tokens: Int?, activity: Date?
        let sessionID = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for record in records {
            guard record.bool("isSidechain") != true else { continue }
            if let id = record.string("sessionId"), id != sessionID { continue }
            if let value = record.string("cwd"), value.hasPrefix("/") { cwd = value }
            if let value = record.string("gitBranch") { branch = value == "HEAD" ? nil : value }
            let type = record.string("type") ?? ""
            if ["user", "assistant", "progress", "system", "attachment"].contains(type),
               let timestamp = Format.parseISO(record.string("timestamp")) {
                activity = max(activity ?? .distantPast, timestamp)
            }
            if type == "assistant", let message = record.dict("message"),
               let value = message.string("model"), !value.isEmpty, !value.hasPrefix("<") {
                model = prettyModel(value)
                if let usage = message.dict("usage") {
                    let count = (usage.int("input_tokens") ?? 0) + (usage.int("cache_read_input_tokens") ?? 0)
                        + (usage.int("cache_creation_input_tokens") ?? 0)
                    if count > 0 { tokens = count }
                }
            }
        }
        guard let cwd, let activity else { return nil }
        return LiveSession(id: path, provider: .claude, project: (cwd as NSString).lastPathComponent, cwd: cwd,
                           model: model, branch: branch, tokens: tokens, tokensLabel: "ctx", lastActivity: activity, isProcessRunning: running)
    }

    private static func codexSessions(since cutoff: Date, processes: [SessionProcess]) -> [LiveSession] {
        let root = Files.codexRoot + "/sessions"
        guard let files = FileManager.default.enumerator(atPath: root) else { return [] }
        let agents = processes.filter { $0.provider == .codex }
        var out: [LiveSession] = []
        while let relative = files.nextObject() as? String {
            guard relative.hasSuffix(".jsonl") else { continue }
            let path = (root as NSString).appendingPathComponent(relative)
            let running = agents.contains { $0.matches(sessionID: SessionProcess.sessionKey(path), path: path) }
            guard let modified = modificationDate(path), modified >= cutoff || running else { continue }
            var cwd: String?, model: String?, tokens: Int?, activity: Date?
            for record in JSONL.edges(path) {
                guard let payload = record.dict("payload") else { continue }
                if ["session_meta", "turn_context"].contains(record.string("type") ?? "") {
                    if let value = payload.string("cwd") { cwd = value }
                    if let value = payload.string("model") { model = value }
                }
                if let count = payload.dict("info")?.dict("total_token_usage")?.int("total_tokens") { tokens = count }
                if let timestamp = Format.parseISO(record.string("timestamp")) { activity = max(activity ?? .distantPast, timestamp) }
            }
            guard let cwd, let activity, activity >= cutoff || running else { continue }
            out.append(LiveSession(id: path, provider: .codex, project: (cwd as NSString).lastPathComponent, cwd: cwd,
                                   model: model, branch: nil, tokens: tokens, tokensLabel: "tok", lastActivity: activity, isProcessRunning: running))
        }
        markNewestRecentSessions(&out, processes: agents, cutoff: cutoff)
        return out
    }

    private static func markNewestRecentSessions(_ sessions: inout [LiveSession], processes: [SessionProcess], cutoff: Date) {
        for process in processes where process.sessionID == nil && process.logs.isEmpty && !process.headless {
            guard let cwd = process.cwd else { continue }
            let candidates = sessions.indices.filter {
                sessions[$0].lastActivity >= cutoff && !sessions[$0].isProcessRunning
                    && URL(fileURLWithPath: sessions[$0].cwd).resolvingSymlinksInPath().path == cwd
            }
            if let newest = candidates.max(by: { sessions[$0].lastActivity < sessions[$1].lastActivity }) { sessions[newest].isProcessRunning = true }
        }
    }

    // MARK: OpenCode

    private static func openCodeSessions(since cutoff: Date, running: Bool) -> [LiveSession] {
        let path = Files.path(".local/share/opencode/opencode.db")
        guard Files.exists(path), let db = try? SQLiteDB(copyOf: path) else { return [] }
        let ms = Int(cutoff.timeIntervalSince1970 * 1000)
        guard let rows = try? db.query("""
            select id, directory, title, model, time_updated, tokens_input + tokens_cache_read + tokens_cache_write
            from session where time_updated >= \(ms) and parent_id is null order by time_updated desc limit 5
            """) else { return [] }
        return rows.compactMap { r in
            guard r.count >= 6, let id = r[0], let dir = r[1], let t = r[4].flatMap(Double.init) else { return nil }
            let model = r[3].map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            return LiveSession(id: "opencode-\(id)", provider: .opencode, project: (dir as NSString).lastPathComponent, cwd: dir,
                               model: model, branch: r[2], tokens: r[5].flatMap(Int.init), tokensLabel: "ctx",
                               lastActivity: Date(timeIntervalSince1970: t / 1000), isProcessRunning: running)
        }
    }

    static func commandLine(_ line: String, matches provider: ProviderID) -> Bool {
        SessionProcess.provider(command: line) == provider
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func prettyModel(_ value: String) -> String {
        var model = value.replacingOccurrences(of: "claude-", with: "")
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) { model.removeSubrange(range) }
        return model
    }
}

/// Bounded reads; incomplete JSONL records at either edge are discarded safely.
enum JSONL {
    static func records(_ data: Data) -> [JSON] {
        data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? JSON }
    }

    static func edges(_ path: String, bytes: Int = 512 * 1024) -> [JSON] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: bytes)) ?? Data()
        guard size > UInt64(bytes) else { return records(head) }
        let offset = max(UInt64(bytes), size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        try? handle.seek(toOffset: offset)
        let tail = (try? handle.readToEnd()) ?? Data()
        return records(head) + records(tail)
    }
}
