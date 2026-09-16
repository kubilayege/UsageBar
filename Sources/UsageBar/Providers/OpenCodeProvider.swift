import Foundation

/// OpenCode: sums token usage and cost from OpenCode's local SQLite database.
/// OpenCode has no rate-limit API, so the windows are informational unless a daily
/// token budget is configured in Settings.
struct OpenCodeProvider: UsageProvider {
    let id = ProviderID.opencode
    var dailyTokenBudget: Int = 0

    private var dbPath: String { Files.path(".local/share/opencode/opencode.db") }

    func fetch() async throws -> UsageSnapshot {
        guard Files.exists(dbPath) else {
            throw ProviderError(.notConfigured, ProviderID.opencode.howToConfigure)
        }
        let db = try SQLiteDB(copyOf: dbPath)
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        let weekAgo = startOfDay.addingTimeInterval(-6 * 86400)
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? startOfDay
        let since = Int(min(weekAgo, monthStart).timeIntervalSince1970 * 1000)

        let rows = try db.query("select data from message where time_created >= \(since) and data like '%\"role\":\"assistant\"%'")
        var today = (tokens: 0, cost: 0.0, n: 0), week = (tokens: 0, cost: 0.0, n: 0), month = (tokens: 0, cost: 0.0, n: 0)
        var providers = Set<String>()
        for row in rows {
            guard let s = row.first ?? nil, let data = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: data) as? JSON else { continue }
            let t = (j.dict("time")?.double("created") ?? 0) / 1000
            let date = Date(timeIntervalSince1970: t)
            let tokens = j.dict("tokens")?.int("total") ?? 0
            let cost = j.double("cost") ?? 0
            if let p = j.string("providerID") { providers.insert(p) }
            if date >= startOfDay { today.tokens += tokens; today.cost += cost; today.n += 1 }
            if date >= weekAgo { week.tokens += tokens; week.cost += cost; week.n += 1 }
            if date >= monthStart { month.tokens += tokens; month.cost += cost; month.n += 1 }
        }

        let endOfDay = startOfDay.addingTimeInterval(86400)
        let hasBudget = dailyTokenBudget > 0
        var windows: [UsageWindow] = []
        windows.append(UsageWindow(
            id: "today", label: "Today",
            percent: hasBudget ? Double(today.tokens) / Double(dailyTokenBudget) * 100 : 0,
            resetsAt: endOfDay, windowDuration: 86400,
            detail: "\(Format.tokens(today.tokens)) tok · \(Format.money(today.cost, "USD"))",
            hasLimit: hasBudget))
        windows.append(UsageWindow(id: "7d", label: "7d", percent: 0, resetsAt: nil, windowDuration: nil,
                                   detail: "\(Format.tokens(week.tokens)) tok · \(Format.money(week.cost, "USD"))", hasLimit: false))
        windows.append(UsageWindow(id: "month", label: "Month", percent: 0, resetsAt: nil, windowDuration: nil,
                                   detail: "\(Format.tokens(month.tokens)) tok · \(Format.money(month.cost, "USD"))", hasLimit: false))

        var plan: String?
        if let auth = Files.readJSON(Files.path(".local/share/opencode/auth.json")) {
            if auth["opencode-go"] != nil { plan = "Go" }
            else if auth["opencode"] != nil { plan = "Zen" }
        }
        let label = providers.sorted().joined(separator: ", ")
        return UsageSnapshot(provider: .opencode, windows: windows, planName: plan,
                             accountLabel: label.isEmpty ? nil : label, note: "\(month.n) messages this month")
    }
}
