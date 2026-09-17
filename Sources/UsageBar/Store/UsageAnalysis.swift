import Foundation

struct AnalysisTurn: Codable, Sendable, Identifiable {
    var id: String
    var provider: ProviderID
    var timestamp: Date
    var model: String
    var effort: String?
    var input: Int
    var cached: Int
    var cacheWrite: Int
    var output: Int
    var recordedCost: Double?
    var tokens: Int { input + cached + cacheWrite + output }
    var modelKey: String { provider.rawValue + "/" + model }
}

struct ModelRates: Codable, Equatable, Sendable {
    var input: Double?
    var cached: Double?
    var cacheWrite: Double?
    var output: Double?

    func cost(_ turn: AnalysisTurn) -> Double? {
        let parts = [(turn.input, input), (turn.cached, cached), (turn.cacheWrite, cacheWrite), (turn.output, output)]
        var total = 0.0
        for (tokens, rate) in parts where tokens > 0 {
            guard let rate, rate.isFinite, rate >= 0 else { return nil }
            total += Double(tokens) * rate / 1_000_000
        }
        return total
    }
}

struct AnalysisRow: Identifiable, Equatable, Sendable {
    var provider: ProviderID
    var model: String
    var effort: String?
    var turns: Int
    var tokens: Int
    var cost: Double?
    var pricedTurns: Int
    var input: Int = 0
    var cached: Int = 0
    var cacheWrite: Int = 0
    var output: Int = 0
    var id: String { provider.rawValue + "/" + model + "/" + (effort ?? "unknown") }
    var tokensPerTurn: Double { Double(tokens) / Double(max(1, turns)) }
    var costPerTurn: Double? { cost.map { $0 / Double(max(1, turns)) } }
}

enum UsageAnalysis {
    static func rows(_ turns: [AnalysisTurn], since: Date, until: Date, enabled: Set<ProviderID>, rates: [String: ModelRates]) -> [AnalysisRow] {
        let eligible = turns.filter { $0.timestamp >= since && $0.timestamp <= until && enabled.contains($0.provider) }
        let groups = Dictionary(grouping: eligible) { $0.modelKey + "/" + ($0.effort ?? "unknown") }
        return groups.values.map { aggregate($0, rates: rates) }.sorted { $0.tokensPerTurn < $1.tokensPerTurn }
    }

    // The table and time plot use the same turn-weighted cost calculation.
    static func aggregate(_ group: [AnalysisTurn], rates: [String: ModelRates]) -> AnalysisRow {
        let first = group[0]
        let costs = group.compactMap { rates[$0.modelKey]?.cost($0) }
        return AnalysisRow(provider: first.provider, model: first.model, effort: first.effort,
                           turns: group.count, tokens: group.reduce(0) { $0 + $1.tokens },
                           cost: costs.count == group.count ? costs.reduce(0, +) : nil, pricedTurns: costs.count,
                           input: group.reduce(0) { $0 + $1.input }, cached: group.reduce(0) { $0 + $1.cached },
                           cacheWrite: group.reduce(0) { $0 + $1.cacheWrite }, output: group.reduce(0) { $0 + $1.output })
    }

    static func cheapest(_ rows: [AnalysisRow]) -> AnalysisRow? {
        // Every compared group needs a price and enough observations. Unknown costs are never zero.
        guard rows.count >= 2, rows.allSatisfy({ $0.turns >= 5 && $0.costPerTurn != nil }) else { return nil }
        return rows.min { $0.costPerTurn! < $1.costPerTurn! }
    }

    static func subscriptionCostPerTurn(monthly: Double?, days: Double, turns: Int) -> Double? {
        guard let monthly, monthly.isFinite, monthly >= 0, days > 0, turns > 0 else { return nil }
        return monthly * days / 30 / Double(turns)
    }
}

/// On-demand analysis. Caches only numerical usage and model metadata, never prompts or responses.
enum UsageAnalysisScanner {
    struct ScanResult: Sendable { var turns: [AnalysisTurn]; var unreadableFiles: Int; var scannedAt: Date }
    private struct CachedFile: Codable { var modified: Date; var size: UInt64; var turns: [AnalysisTurn] }
    private struct Cache: Codable { var version = 1; var files: [String: CachedFile] = [:] }

    static func scan(now: Date = Date()) -> ScanResult {
        let cacheURL = Files.appSupport.appendingPathComponent("analysis-cache.json")
        var cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        if cache.version != 1 { cache = Cache() }
        let cutoff = now.addingTimeInterval(-120 * 86400)
        var seen = Set<String>(), all: [AnalysisTurn] = [], unreadable = 0
        for (provider, root) in [(ProviderID.claude, Files.claudeRoot + "/projects"), (.codex, Files.codexRoot + "/sessions")] {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            while let relative = enumerator.nextObject() as? String {
                guard relative.hasSuffix(".jsonl") else { continue }
                let path = root + "/" + relative
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date,
                      let size = (attributes[.size] as? NSNumber)?.uint64Value else { unreadable += 1; continue }
                guard modified >= cutoff else { continue }
                seen.insert(path)
                if let entry = cache.files[path], entry.modified == modified && entry.size == size { all += entry.turns; continue }
                guard let turns = parse(path, provider: provider) else { unreadable += 1; continue }
                let recent = turns.filter { $0.timestamp >= cutoff }
                cache.files[path] = CachedFile(modified: modified, size: size, turns: recent)
                all += recent
            }
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
        all += openCode(since: cutoff)
        // Resumed/copied session logs and streaming chunks can contain the same response more than once.
        var unique: [String: AnalysisTurn] = [:]
        for turn in all {
            if let previous = unique[turn.id], previous.tokens > turn.tokens { continue }
            unique[turn.id] = turn
        }
        return ScanResult(turns: unique.values.sorted { $0.timestamp < $1.timestamp }, unreadableFiles: unreadable, scannedAt: now)
    }

    static func parse(_ path: String, provider: ProviderID) -> [AnalysisTurn]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        var turns: [String: AnalysisTurn] = [:]
        var model = "Not recorded", effort: String?, previousTotal: [String: Int]?
        var session = SessionProcess.sessionKey(path)
        for line in data.split(separator: 10) {
            // Only decode metadata and token records; message text is never retained.
            let interesting = ["\"usage\"", "\"token_count\"", "\"turn_context\"", "\"session_meta\""].contains {
                line.range(of: Data($0.utf8)) != nil
            }
            guard interesting, let record = try? JSONSerialization.jsonObject(with: Data(line)) as? JSON else { continue }
            if provider == .claude {
                guard record.string("type") == "assistant", let message = record.dict("message"),
                      let usage = message.dict("usage"), let timestamp = Format.parseISO(record.string("timestamp")),
                      let name = message.string("model"), !name.hasPrefix("<") else { continue }
                let request = message.string("id") ?? record.string("requestId") ?? record.string("uuid") ?? record.string("timestamp")!
                let id = "claude/" + request
                let turn = AnalysisTurn(id: id, provider: .claude, timestamp: timestamp, model: name,
                    effort: message.string("effort") ?? record.string("effort"),
                    input: max(0, usage.int("input_tokens") ?? 0), cached: max(0, usage.int("cache_read_input_tokens") ?? 0),
                    cacheWrite: max(0, usage.int("cache_creation_input_tokens") ?? 0), output: max(0, usage.int("output_tokens") ?? 0))
                if turn.tokens >= (turns[id]?.tokens ?? 0) { turns[id] = turn }
            } else if provider == .codex, let payload = record.dict("payload") {
                if record.string("type") == "session_meta" { session = payload.string("id") ?? session }
                if record.string("type") == "turn_context" {
                    model = payload.string("model") ?? "Not recorded"
                    effort = payload.string("effort") ?? payload.string("reasoning_effort")
                }
                guard payload.string("type") == "token_count", let info = payload.dict("info"),
                      let total = info.dict("total_token_usage"), let timestamp = Format.parseISO(record.string("timestamp")) else { continue }
                let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "total_tokens"]
                let current = Dictionary(uniqueKeysWithValues: keys.map { ($0, max(0, total.int($0) ?? 0)) })
                let cumulative = current["total_tokens"] ?? 0
                if let previousTotal, cumulative == previousTotal["total_tokens"] { continue }
                var delta: [String: Int]
                if let previousTotal, cumulative > (previousTotal["total_tokens"] ?? 0) {
                    delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, max(0, (current[$0] ?? 0) - (previousTotal[$0] ?? 0))) })
                } else if let last = info.dict("last_token_usage") {
                    delta = Dictionary(uniqueKeysWithValues: keys.map { ($0, max(0, last.int($0) ?? 0)) })
                } else {
                    previousTotal = current
                    continue // No reliable per-response delta for this first record.
                }
                previousTotal = current
                let cached = min(delta["cached_input_tokens"] ?? 0, delta["input_tokens"] ?? 0)
                let id = "codex/" + session + "/" + String(cumulative)
                let turn = AnalysisTurn(id: id, provider: .codex, timestamp: timestamp, model: model, effort: effort,
                    input: max(0, (delta["input_tokens"] ?? 0) - cached), cached: cached,
                    cacheWrite: delta["cache_write_input_tokens"] ?? 0, output: delta["output_tokens"] ?? 0)
                if turn.tokens > 0 { turns[id] = turn }
            }
        }
        return Array(turns.values)
    }

    private static func openCode(since: Date) -> [AnalysisTurn] {
        guard let db = try? SQLiteDB(copyOf: Files.path(".local/share/opencode/opencode.db")),
              let rows = try? db.query("select id, data from message where time_created >= \(Int(since.timeIntervalSince1970 * 1000))") else { return [] }
        return rows.compactMap { row in
            guard row.count == 2, let id = row[0], let raw = row[1]?.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: raw) as? JSON, record.string("role") == "assistant",
                  let tokens = record.dict("tokens"), let created = record.dict("time")?.double("created") else { return nil }
            return AnalysisTurn(id: "opencode/" + id, provider: .opencode, timestamp: Date(timeIntervalSince1970: created / 1000),
                model: record.string("modelID") ?? "Not recorded", effort: nil,
                input: max(0, tokens.int("input") ?? 0), cached: max(0, tokens.dict("cache")?.int("read") ?? 0),
                cacheWrite: max(0, tokens.dict("cache")?.int("write") ?? 0), output: max(0, tokens.int("output") ?? 0),
                recordedCost: record.double("cost"))
        }
    }
}
