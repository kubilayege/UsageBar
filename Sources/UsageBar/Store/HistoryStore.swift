import Foundation

/// Append-only local log of usage percentages, used for trend charts. Lives in
/// ~/Library/Application Support/UsageBar/history.jsonl and never leaves the device.
final class HistoryStore {
    private let url = Files.appSupport.appendingPathComponent("history.jsonl")
    private(set) var points: [HistoryPoint] = []
    private var lastRecorded: [String: HistoryPoint] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxAge: TimeInterval = 45 * 86400

    init() {
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
        load()
    }

    private func load() {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        var loaded: [HistoryPoint] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let p = try? decoder.decode(HistoryPoint.self, from: line), p.t >= cutoff { loaded.append(p) }
        }
        points = loaded
        for p in loaded { lastRecorded[key(p.p, p.a, p.w)] = p }
        // Compact the file if it drifted far from what we kept.
        if loaded.count < data.count / 200 { rewrite() }
    }

    private func key(_ provider: ProviderID, _ account: String?, _ window: String) -> String {
        "\(provider.rawValue)/\(account.map { $0 + "/" } ?? "")\(window)"
    }

    func record(_ snapshot: UsageSnapshot, account: String? = nil) {
        let now = Date()
        var appended: [HistoryPoint] = []
        for w in snapshot.windows where w.hasLimit {
            let key = key(snapshot.provider, account, w.id)
            if let last = lastRecorded[key], now.timeIntervalSince(last.t) < 300, abs(last.pct - w.percent) < 1 { continue }
            let p = HistoryPoint(t: now, p: snapshot.provider, a: account, w: w.id, pct: w.percent, proj: w.projectedPercent(now: now))
            lastRecorded[key] = p
            appended.append(p)
        }
        guard !appended.isEmpty else { return }
        points.append(contentsOf: appended)
        var data = Data()
        for p in appended { if let d = try? encoder.encode(p) { data.append(d); data.append(UInt8(ascii: "\n")) } }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func rewrite() {
        var data = Data()
        for p in points { if let d = try? encoder.encode(p) { data.append(d); data.append(UInt8(ascii: "\n")) } }
        try? data.write(to: url)
    }

    /// `includeUnkeyed` adds points recorded before this provider had several accounts.
    func series(provider: ProviderID, account: String? = nil, includeUnkeyed: Bool = true, since: Date) -> [HistoryPoint] {
        points.filter { $0.p == provider && $0.t >= since && ($0.a == account || (includeUnkeyed && $0.a == nil)) }
    }
}
