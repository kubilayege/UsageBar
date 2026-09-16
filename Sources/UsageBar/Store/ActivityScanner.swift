import Foundation

/// Builds a per-day token/message activity map from local session logs:
/// Claude Code (~/.claude/projects), Codex (~/.codex/sessions) and OpenCode (sqlite).
/// Results are cached per file (mtime+size) so only changed logs are re-parsed.
enum ActivityScanner {
    private struct FileCache: Codable { var mtime: Double; var size: Int; var days: [String: DayCount] }
    private struct DayCount: Codable { var tokens: Int; var messages: Int }
    private struct Cache: Codable { var files: [String: FileCache] = [:] }

    private static let cacheURL = Files.appSupport.appendingPathComponent("activity-cache.json")
    private static let lookback: TimeInterval = 120 * 86400

    static func scan() -> ActivityData {
        var cache = loadCache()
        var totals: [String: [String: DayCount]] = [:] // provider -> day -> counts
        let cutoff = Date().addingTimeInterval(-lookback)
        var seenPaths = Set<String>()

        func accumulate(_ provider: ProviderID, _ days: [String: DayCount]) {
            var bucket = totals[provider.rawValue] ?? [:]
            for (day, c) in days {
                var cur = bucket[day] ?? DayCount(tokens: 0, messages: 0)
                cur.tokens += c.tokens; cur.messages += c.messages
                bucket[day] = cur
            }
            totals[provider.rawValue] = bucket
        }

        for (provider, root) in [(ProviderID.claude, Files.path(".claude/projects")), (.codex, Files.path(".codex/sessions"))] {
            for path in jsonlFiles(under: root) {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let mtime = (attrs[.modificationDate] as? Date), let size = attrs[.size] as? Int else { continue }
                guard mtime >= cutoff else { continue }
                seenPaths.insert(path)
                if let c = cache.files[path], c.mtime == mtime.timeIntervalSince1970, c.size == size {
                    accumulate(provider, c.days)
                    continue
                }
                let days = provider == .claude ? parseClaude(path) : parseCodex(path)
                cache.files[path] = FileCache(mtime: mtime.timeIntervalSince1970, size: size, days: days)
                accumulate(provider, days)
            }
        }
        cache.files = cache.files.filter { seenPaths.contains($0.key) }
        saveCache(cache)

        var costs: [String: Double] = [:]
        if let (days, c) = openCodeActivity(since: cutoff) { accumulate(.opencode, days); costs = c }

        var out: [DayActivity] = []
        for (pRaw, days) in totals {
            guard let p = ProviderID(rawValue: pRaw) else { continue }
            for (day, c) in days {
                out.append(DayActivity(day: day, provider: p, tokens: c.tokens, messages: c.messages,
                                       cost: p == .opencode ? (costs[day] ?? 0) : 0))
            }
        }
        return ActivityData(days: out.sorted { $0.day < $1.day }, scannedAt: Date())
    }

    // MARK: Parsers (byte-level; these logs can be hundreds of MB)

    private enum Keys {
        static let typeAssistant = Array("\"type\":\"assistant\"".utf8)
        static let usage = Array("\"usage\"".utf8)
        static let input = Array("\"input_tokens\":".utf8)
        static let output = Array("\"output_tokens\":".utf8)
        static let cacheCreate = Array("\"cache_creation_input_tokens\":".utf8)
        static let cacheRead = Array("\"cache_read_input_tokens\":".utf8)
        static let timestamp = Array("\"timestamp\":\"".utf8)
        static let requestId = Array("\"requestId\":\"".utf8)
        static let tokenCount = Array("\"token_count\"".utf8)
        static let lastUsage = Array("\"last_token_usage\":".utf8)
        static let totalTokens = Array("\"total_tokens\":".utf8)
    }

    private static func parseClaude(_ path: String) -> [String: DayCount] {
        var days: [String: DayCount] = [:]
        var seen = Set<String>()
        var dayCache: [String: String] = [:]
        forEachLine(path, containing: Keys.usage) { line in
            guard line.contains(Keys.typeAssistant), let ts = line.string(after: Keys.timestamp) else { return }
            let key = line.string(after: Keys.requestId) ?? ts
            guard !seen.contains(key) else { return }
            seen.insert(key)
            guard let day = localDay(ts, &dayCache) else { return }
            let tokens = (line.int(after: Keys.input) ?? 0) + (line.int(after: Keys.output) ?? 0)
                + (line.int(after: Keys.cacheCreate) ?? 0) + (line.int(after: Keys.cacheRead) ?? 0)
            var cur = days[day] ?? DayCount(tokens: 0, messages: 0)
            cur.tokens += tokens; cur.messages += 1
            days[day] = cur
        }
        return days
    }

    private static func parseCodex(_ path: String) -> [String: DayCount] {
        var days: [String: DayCount] = [:]
        var dayCache: [String: String] = [:]
        forEachLine(path, containing: Keys.tokenCount) { line in
            guard let at = line.find(Keys.lastUsage), let ts = line.string(after: Keys.timestamp) else { return }
            guard let tokens = line.int(after: Keys.totalTokens, from: at), tokens > 0 else { return }
            guard let day = localDay(ts, &dayCache) else { return }
            var cur = days[day] ?? DayCount(tokens: 0, messages: 0)
            cur.tokens += tokens; cur.messages += 1
            days[day] = cur
        }
        return days
    }

    /// Converts an ISO timestamp to a local yyyy-MM-dd key, caching per UTC hour.
    private static func localDay(_ ts: String, _ cache: inout [String: String]) -> String? {
        let hour = String(ts.prefix(13))
        if let d = cache[hour] { return d }
        guard let date = Format.parseISO(ts) else { return nil }
        let key = Format.dayKey(date)
        cache[hour] = key
        return key
    }

    private static func openCodeActivity(since: Date) -> ([String: DayCount], [String: Double])? {
        let path = Files.path(".local/share/opencode/opencode.db")
        guard let db = try? SQLiteDB(copyOf: path) else { return nil }
        let ms = Int(since.timeIntervalSince1970 * 1000)
        guard let rows = try? db.query("select data from message where time_created >= \(ms) and data like '%\"role\":\"assistant\"%'") else { return nil }
        var days: [String: DayCount] = [:]
        var costs: [String: Double] = [:]
        for row in rows {
            guard let s = row.first ?? nil, let data = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
            let t = (j.dict("time")?.double("created") ?? 0) / 1000
            let day = Format.dayKey(Date(timeIntervalSince1970: t))
            var cur = days[day] ?? DayCount(tokens: 0, messages: 0)
            cur.tokens += j.dict("tokens")?.int("total") ?? 0
            cur.messages += 1
            days[day] = cur
            costs[day, default: 0] += j.double("cost") ?? 0
        }
        return (days, costs)
    }

    // MARK: Helpers

    private static func jsonlFiles(under root: String) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let rel = e.nextObject() as? String {
            if rel.hasSuffix(".jsonl") { out.append((root as NSString).appendingPathComponent(rel)) }
        }
        return out
    }

    private struct ByteLine {
        let base: UnsafePointer<UInt8>
        let count: Int

        func find(_ needle: [UInt8], from: Int = 0) -> Int? {
            guard from < count, needle.count <= count - from else { return nil }
            return needle.withUnsafeBufferPointer { nb -> Int? in
                guard let hit = memmem(base + from, count - from, nb.baseAddress, nb.count) else { return nil }
                return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
            }
        }

        func contains(_ needle: [UInt8]) -> Bool { find(needle) != nil }

        func int(after key: [UInt8], from: Int = 0) -> Int? {
            guard var i = find(key, from: from) else { return nil }
            i += key.count
            while i < count, base[i] == 0x20 { i += 1 }
            var value = 0, any = false
            while i < count, base[i] >= 0x30, base[i] <= 0x39 {
                value = value * 10 + Int(base[i] - 0x30); i += 1; any = true
            }
            return any ? value : nil
        }

        func string(after key: [UInt8], from: Int = 0) -> String? {
            guard var i = find(key, from: from) else { return nil }
            i += key.count
            let start = i
            while i < count, base[i] != 0x22 { i += 1 }
            return String(decoding: UnsafeBufferPointer(start: base + start, count: i - start), as: UTF8.self)
        }
    }

    private static func forEachLine(_ path: String, containing needle: [UInt8], _ body: (ByteLine) -> Void) {
        guard let data = FileManager.default.contents(atPath: path) else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let total = raw.count
            var start = 0
            while start < total {
                var end = start
                if let nl = memchr(base + start, 0x0A, total - start) {
                    end = UnsafeRawPointer(nl) - UnsafeRawPointer(base)
                } else {
                    end = total
                }
                if end > start {
                    let line = ByteLine(base: base + start, count: end - start)
                    if line.contains(needle) { body(line) }
                }
                start = end + 1
            }
        }
    }

    private static func loadCache() -> Cache {
        guard let data = FileManager.default.contents(atPath: cacheURL.path),
              let c = try? JSONDecoder().decode(Cache.self, from: data) else { return Cache() }
        return c
    }

    private static func saveCache(_ c: Cache) {
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: cacheURL) }
    }
}
