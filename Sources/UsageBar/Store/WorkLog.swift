import Foundation

// MARK: - Scanned data

/// One agent session's work on one local day. Minutes are whole minutes since 1970, sorted and unique.
struct WorkDay: Codable, Sendable, Equatable {
    var minutes: [Int] = []
    /// Path relative to the session's working directory (file name only outside it) → edits.
    var files: [String: Int] = [:]
    /// Model → token usage.
    var usage: [String: WorkUsage] = [:]
}

struct WorkUsage: Codable, Sendable, Equatable {
    var turns = 0, input = 0, cached = 0, cacheWrite = 0, output = 0
    var recordedCost: Double?
    var tokens: Int { input + cached + cacheWrite + output }

    mutating func add(_ other: WorkUsage) {
        turns += other.turns; input += other.input; cached += other.cached; cacheWrite += other.cacheWrite; output += other.output
        if let c = other.recordedCost { recordedCost = (recordedCost ?? 0) + c }
    }
}

struct WorkSession: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var provider: ProviderID
    var cwd: String
    var title: String?
    var branch: String?
    var days: [String: WorkDay]
    /// Git root (or cwd) the session is grouped under. Resolved after merging, never cached.
    var project: String = ""
}

struct WorkLogData: Sendable {
    var sessions: [WorkSession]
    var scannedAt: Date
}

// MARK: - Scanner

/// Reads local agent logs into per-session, per-day work. Keeps timing, file names and token counts;
/// never prompts, responses or file contents. Results are cached per log file (mtime + size).
enum WorkLogScanner {
    static let lookback: TimeInterval = 120 * 86400
    private static let cacheVersion = 1
    private struct CachedFile: Codable { var mtime: Double; var size: Int; var sessions: [WorkSession] }
    private struct Cache: Codable { var version = WorkLogScanner.cacheVersion; var files: [String: CachedFile] = [:] }
    private static var cacheURL: URL { Files.appSupport.appendingPathComponent("worklog-cache.json") }

    static func scan(now: Date = Date()) -> WorkLogData {
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        if cache.version != cacheVersion { cache = Cache() }
        let cutoff = now.addingTimeInterval(-lookback)
        var seen = Set<String>(), found: [WorkSession] = []
        var pending: [(path: String, provider: ProviderID, mtime: Double, size: Int)] = []
        for (provider, root) in [(ProviderID.claude, Files.claudeRoot + "/projects"), (.codex, Files.codexRoot + "/sessions")] {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".jsonl") else { continue }
                let path = root + "/" + relative
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date, modified >= cutoff,
                      let size = (attributes[.size] as? NSNumber)?.intValue else { continue }
                seen.insert(path)
                if let entry = cache.files[path], entry.mtime == modified.timeIntervalSince1970, entry.size == size {
                    found += entry.sessions
                    continue
                }
                pending.append((path, provider, modified.timeIntervalSince1970, size))
            }
        }
        let parsed = parallelMap(pending) { $0.provider == .claude ? parseClaude($0.path) : parseCodex($0.path) }
        for (file, sessions) in zip(pending, parsed) {
            cache.files[file.path] = CachedFile(mtime: file.mtime, size: file.size, sessions: sessions)
            found += sessions
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        found += openCode(since: cutoff)
        return WorkLogData(sessions: merge(found, codexTitles: codexTitles(), cutoffDay: Format.dayKey(cutoff)), scannedAt: now)
    }

    /// Sub-agent logs share their parent's session id, so they fold into the parent session here.
    static func merge(_ sessions: [WorkSession], codexTitles: [String: String] = [:], cutoffDay: String = "") -> [WorkSession] {
        var merged: [String: WorkSession] = [:]
        for s in sessions {
            guard var current = merged[s.id] else { merged[s.id] = s; continue }
            if current.cwd.isEmpty { current.cwd = s.cwd }
            current.title = current.title ?? s.title
            current.branch = current.branch ?? s.branch
            for (day, work) in s.days {
                var d = current.days[day] ?? WorkDay()
                d.minutes = Array(Set(d.minutes).union(work.minutes)).sorted()
                d.files.merge(work.files, uniquingKeysWith: +)
                for (model, usage) in work.usage { d.usage[model, default: WorkUsage()].add(usage) }
                current.days[day] = d
            }
            merged[s.id] = current
        }
        var roots: [String: String] = [:]
        return merged.values.compactMap { s in
            var s = s
            if s.provider == .codex, let key = s.id.split(separator: "/").last, let title = codexTitles[String(key)] { s.title = title }
            s.title = s.title.flatMap(cleanTitle)
            s.days = s.days.filter { $0.key >= cutoffDay && !$0.value.minutes.isEmpty }
            guard !s.days.isEmpty, !s.cwd.isEmpty else { return nil }
            if let root = roots[s.cwd] { s.project = root } else { s.project = projectRoot(s.cwd); roots[s.cwd] = s.project }
            return s
        }
    }

    // MARK: Claude Code

    private enum Keys {
        static let sessionId = Array("\"sessionId\":\"".utf8)
        static let user = Array("\"type\":\"user\"".utf8)
        static let assistant = Array("\"type\":\"assistant\"".utf8)
        static let timestamp = Array("\"timestamp\":\"".utf8)
        static let cwd = Array("\"cwd\":\"".utf8)
        static let branch = Array("\"gitBranch\":\"".utf8)
        static let aiTitle = Array("\"type\":\"ai-title\"".utf8)
        static let customTitle = Array("\"type\":\"custom-title\"".utf8)
        static let toolUse = Array("\"type\":\"tool_use\"".utf8)
        static let editTools = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
        static let editNeedles = editTools.map { Array("\"name\":\"\($0)\"".utf8) }
        static let sessionMeta = Array("\"type\":\"session_meta\"".utf8)
        static let turnContext = Array("\"type\":\"turn_context\"".utf8)
        static let responseItem = Array("\"type\":\"response_item\"".utf8)
        static let patch = Array("*** Begin Patch".utf8)
    }

    private final class Builder {
        var cwd = "", branch: String?, title: String?, customTitle: String?
        var minutes: [String: Set<Int>] = [:]
        var files: [String: [String: Int]] = [:]
        var usage: [String: [String: WorkUsage]] = [:]

        func touch(_ minute: Int, _ day: String) { minutes[day, default: []].insert(minute) }
        func edit(_ path: String, _ day: String) {
            let name = WorkLogScanner.relativePath(path, cwd: cwd)
            guard !name.isEmpty else { return }
            files[day, default: [:]][name, default: 0] += 1
        }
        func add(_ turns: [AnalysisTurn]) {
            for turn in turns {
                let day = Format.dayKey(turn.timestamp)
                usage[day, default: [:]][turn.model, default: WorkUsage()].add(WorkUsage(
                    turns: 1, input: turn.input, cached: turn.cached, cacheWrite: turn.cacheWrite, output: turn.output,
                    recordedCost: turn.recordedCost))
            }
        }
        func session(id: String, provider: ProviderID) -> WorkSession {
            var days: [String: WorkDay] = [:]
            for (day, set) in minutes { days[day] = WorkDay(minutes: set.sorted(), files: files[day] ?? [:], usage: usage[day] ?? [:]) }
            return WorkSession(id: provider.rawValue + "/" + id, provider: provider, cwd: cwd, title: customTitle ?? title, branch: branch, days: days)
        }
    }

    static func parseClaude(_ path: String) -> [WorkSession] {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var builders: [String: Builder] = [:]
        var clock = MinuteClock()
        ActivityScanner.forEachLine(path) { line in
            // Record metadata sits before or after the message body, so only the line's edges are searched.
            let id = line.edgeString(after: Keys.sessionId) ?? stem
            let b = builders[id] ?? { let b = Builder(); builders[id] = b; return b }()
            if line.edge(Keys.aiTitle) != nil || line.edge(Keys.customTitle) != nil {
                guard let record = line.json() else { return }
                if let t = record.string("aiTitle") { b.title = t }
                if let t = record.string("customTitle") { b.customTitle = t }
                return
            }
            let isAssistant = line.edge(Keys.assistant) != nil
            guard isAssistant || line.edge(Keys.user) != nil,
                  let ts = line.edgeString(after: Keys.timestamp), let (minute, day) = clock.resolve(ts) else { return }
            if let cwd = line.edgeString(after: Keys.cwd), cwd.hasPrefix("/") { b.cwd = cwd }
            if let branch = line.edgeString(after: Keys.branch), !branch.isEmpty { b.branch = branch == "HEAD" ? nil : branch }
            b.touch(minute, day)
            guard isAssistant, line.contains(Keys.toolUse), Keys.editNeedles.contains(where: line.contains), let record = line.json(),
                  let content = record.dict("message")?.array("content") as? [JSON] else { return }
            for item in content where item.string("type") == "tool_use" && Keys.editTools.contains(item.string("name") ?? "") {
                if let file = item.dict("input")?.string("file_path") ?? item.dict("input")?.string("notebook_path") { b.edit(file, day) }
            }
        }
        // Token usage comes from the analysis parser so both views count a turn the same way.
        if let main = builders.max(by: { $0.value.minutes.values.reduce(0) { $0 + $1.count } < $1.value.minutes.values.reduce(0) { $0 + $1.count } })?.value {
            main.add(UsageAnalysisScanner.parse(path, provider: .claude) ?? [])
        }
        return builders.map { $0.value.session(id: $0.key, provider: .claude) }.filter { !$0.days.isEmpty }
    }

    // MARK: Codex

    private static let patchFile = try! NSRegularExpression(pattern: #"\*\*\* (?:(?:Add|Update|Delete) File|Move to): ([^\n"\\]+)"#)

    static func patchedFiles(_ text: String) -> [String] {
        patchFile.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) }
        }.filter { !$0.isEmpty }
    }

    static func parseCodex(_ path: String) -> [WorkSession] {
        let b = Builder()
        var id = SessionProcess.sessionKey(path)
        var clock = MinuteClock()
        ActivityScanner.forEachLine(path) { line in
            guard let ts = line.edgeString(after: Keys.timestamp), let (minute, day) = clock.resolve(ts) else { return }
            b.touch(minute, day)
            let meta = line.edge(Keys.sessionMeta) != nil
            if meta || line.edge(Keys.turnContext) != nil {
                guard let payload = line.json()?.dict("payload") else { return }
                // Sub-agents record their parent's id as session_id.
                if meta { id = payload.string("session_id") ?? payload.string("id") ?? id }
                if let cwd = payload.string("cwd"), cwd.hasPrefix("/") { b.cwd = cwd }
                if let branch = payload.dict("git")?.string("branch"), !branch.isEmpty { b.branch = branch }
                return
            }
            guard line.edge(Keys.responseItem) != nil, line.contains(Keys.patch), let payload = line.json()?.dict("payload"),
                  ["custom_tool_call", "function_call"].contains(payload.string("type") ?? "") else { return }
            for file in patchedFiles(payload.string("input") ?? payload.string("arguments") ?? "") { b.edit(file, day) }
        }
        b.add(UsageAnalysisScanner.parse(path, provider: .codex) ?? [])
        let session = b.session(id: id, provider: .codex)
        return session.days.isEmpty ? [] : [session]
    }

    private static func codexTitles() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: Files.codexRoot + "/session_index.jsonl") else { return [:] }
        var out: [String: String] = [:]
        for record in JSONL.records(data) {
            if let id = record.string("id"), let name = record.string("thread_name"), !name.isEmpty { out[id] = name }
        }
        return out
    }

    // MARK: OpenCode

    private static func openCode(since: Date) -> [WorkSession] {
        guard let db = try? SQLiteDB(copyOf: Files.path(".local/share/opencode/opencode.db")) else { return [] }
        let ms = Int(since.timeIntervalSince1970 * 1000)
        guard let sessions = try? db.query("select id, parent_id, directory, title from session where time_updated >= \(ms)") else { return [] }
        var parent: [String: String] = [:], builders: [String: Builder] = [:]
        for row in sessions where row.count == 4 {
            guard let id = row[0] else { continue }
            if let p = row[1] { parent[id] = p; continue }
            let b = Builder()
            b.cwd = row[2] ?? ""
            b.title = row[3].flatMap { $0.hasPrefix("New session") ? nil : $0 }
            builders[id] = b
        }
        func builder(_ id: String?) -> Builder? {
            guard var id else { return nil }
            while let p = parent[id] { id = p }
            return builders[id]
        }
        for row in (try? db.query("select session_id, time_created, data from message where time_created >= \(ms)")) ?? [] where row.count == 3 {
            guard let b = builder(row[0]), let t = row[1].flatMap(Double.init) else { continue }
            let date = Date(timeIntervalSince1970: t / 1000)
            let day = Format.dayKey(date)
            b.touch(Int(date.timeIntervalSince1970 / 60), day)
            guard let raw = row[2]?.data(using: .utf8), let record = try? JSONSerialization.jsonObject(with: raw) as? JSON,
                  record.string("role") == "assistant", let tokens = record.dict("tokens") else { continue }
            b.usage[day, default: [:]][record.string("modelID") ?? "Not recorded", default: WorkUsage()].add(WorkUsage(
                turns: 1, input: max(0, tokens.int("input") ?? 0), cached: max(0, tokens.dict("cache")?.int("read") ?? 0),
                cacheWrite: max(0, tokens.dict("cache")?.int("write") ?? 0), output: max(0, tokens.int("output") ?? 0),
                recordedCost: record.double("cost")))
        }
        let edits = "select session_id, time_created, data from part where time_created >= \(ms) and (data like '%\"tool\":\"edit\"%' or data like '%\"tool\":\"write\"%')"
        for row in (try? db.query(edits)) ?? [] where row.count == 3 {
            guard let b = builder(row[0]), let t = row[1].flatMap(Double.init), let raw = row[2]?.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: raw) as? JSON,
                  let file = record.dict("state")?.dict("input")?.string("filePath") else { continue }
            b.edit(file, Format.dayKey(Date(timeIntervalSince1970: t / 1000)))
        }
        return builders.map { $0.value.session(id: $0.key, provider: .opencode) }.filter { !$0.days.isEmpty }
    }

    // MARK: Helpers

    /// Keeps paths inside the project relative; anything outside is reduced to its file name.
    static func relativePath(_ path: String, cwd: String) -> String {
        guard path.hasPrefix("/") else { return path }
        if !cwd.isEmpty, path.hasPrefix(cwd + "/") { return String(path.dropFirst(cwd.count + 1)) }
        return (path as NSString).lastPathComponent
    }

    /// Groups sub-directories and agent worktrees under the repository they belong to.
    static func projectRoot(_ cwd: String) -> String {
        var path = cwd
        if let r = path.range(of: "/.claude/worktrees/") { path = String(path[..<r.lowerBound]) }
        if let r = path.range(of: "/.codex/worktrees/") {
            // ~/.codex/worktrees/<id>/<repo>/…  →  ~/.codex/worktrees/<repo>
            let rest = path[r.upperBound...].split(separator: "/")
            if rest.count >= 2 { return String(path[..<r.upperBound]) + rest[1] }
        }
        let fm = FileManager.default
        var dir = path
        while dir.count > 1, dir != Files.home {
            if fm.fileExists(atPath: dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return path
    }

    static func cleanTitle(_ raw: String) -> String? {
        let t = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return t.count > 90 ? String(t.prefix(89)) + "…" : t
    }
}

/// Resolves ISO timestamps to (minute since 1970, local day), parsing each UTC minute once.
struct MinuteClock {
    private var cache: [Substring: (Int, String)] = [:]
    mutating func resolve(_ ts: String) -> (Int, String)? {
        let cacheable = ts.hasSuffix("Z") && ts.count >= 17
        let key = ts.prefix(16)
        if cacheable, let hit = cache[key] { return hit }
        guard let date = Format.parseISO(ts) else { return nil }
        let value = (Int((date.timeIntervalSince1970 / 60).rounded(.down)), Format.dayKey(date))
        if cacheable { cache[key] = value }
        return value
    }
}

extension ActivityScanner.ByteLine {
    func json() -> JSON? {
        try? JSONSerialization.jsonObject(with: Data(bytes: base, count: count)) as? JSON
    }

    private static let head = 768, tail = 4096

    /// Finds a top-level key near the start or end of a record without scanning a large message body,
    /// falling back to the whole line when neither edge has it.
    func edge(_ needle: [UInt8]) -> Int? {
        guard count > Self.head + Self.tail else { return find(needle) }
        if let i = find(needle, from: 0, to: Self.head + needle.count) { return i }
        if let i = find(needle, from: count - Self.tail) { return i }
        return find(needle, from: Self.head)
    }

    func edgeString(after key: [UInt8]) -> String? {
        guard let i = edge(key) else { return nil }
        return string(after: key, from: i)
    }
}

/// Order-preserving concurrent map for independent file parses.
func parallelMap<T, R>(_ items: [T], _ transform: (T) -> R) -> [R] {
    guard items.count > 1 else { return items.map(transform) }
    var results = [R?](repeating: nil, count: items.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let value = transform(items[i])
        lock.lock(); results[i] = value; lock.unlock()
    }
    return results.map { $0! }
}
