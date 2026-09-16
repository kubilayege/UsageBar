import Foundation

/// OpenAI Codex CLI: reads the ChatGPT OAuth token from ~/.codex/auth.json and asks the
/// Codex backend for its rate-limit windows (the same data `codex` shows in /status).
struct CodexProvider: UsageProvider {
    let id = ProviderID.codex

    func fetch() async throws -> UsageSnapshot {
        let path = Files.path(".codex/auth.json")
        guard let auth = Files.readJSON(path) else {
            throw ProviderError(.notConfigured, ProviderID.codex.howToConfigure)
        }
        guard let tokens = auth.dict("tokens"), let access = tokens.string("access_token"), !access.isEmpty else {
            if auth.string("OPENAI_API_KEY") != nil {
                throw ProviderError(.notConfigured, "Codex is using an API key. Sign in with ChatGPT (`codex login`) to see rate limits.")
            }
            throw ProviderError(.notConfigured, ProviderID.codex.howToConfigure)
        }
        var headers = ["Authorization": "Bearer \(access)"]
        if let acc = tokens.string("account_id") { headers["ChatGPT-Account-Id"] = acc }

        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let (data, resp) = try await HTTP.request(url, headers: headers)
        switch resp.statusCode {
        case 200: break
        case 401, 403: throw ProviderError(.auth, "Codex token expired — run `codex` once to refresh it")
        case 429:
            let retry = resp.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 120
            throw ProviderError(.rateLimited, "Codex asked us to slow down", retryAfter: max(60, retry))
        default: throw ProviderError(.network, "Codex backend returned HTTP \(resp.statusCode)")
        }
        let json = try HTTP.jsonObject(data)
        return try parse(json)
    }

    func parse(_ json: JSON) throws -> UsageSnapshot {
        var windows: [UsageWindow] = []
        if let rl = json.dict("rate_limit") {
            if let w = window(rl.dict("primary_window"), idPrefix: "") { windows.append(w) }
            if let w = window(rl.dict("secondary_window"), idPrefix: "") { windows.append(w) }
        }
        // Model-specific limits (e.g. Spark) — shown as secondary rows only when used.
        for case let item as JSON in json.array("additional_rate_limits") ?? [] {
            let name = item.string("limit_name") ?? "Extra"
            guard let rl = item.dict("rate_limit") else { continue }
            for key in ["primary_window", "secondary_window"] {
                if var w = window(rl.dict(key), idPrefix: name + " "), w.percent > 0 {
                    w.label = "\(name) \(w.label)"
                    w.isPrimary = false
                    windows.append(w)
                }
            }
        }
        guard !windows.isEmpty else { throw ProviderError(.parse, "No rate-limit windows in response") }
        windows.sort { ($0.windowDuration ?? 0) < ($1.windowDuration ?? 0) }

        var extra: ExtraUsage?
        if let credits = json.dict("credits"), credits.bool("has_credits") == true {
            let balance = credits.double("balance") ?? 0
            extra = ExtraUsage(title: "Credits", used: nil, limit: nil, utilization: nil, currency: nil)
            extra?.used = balance
        }

        let plan = planName(json.string("plan_type"))
        let email = json.string("email")
        var note: String?
        if let rl = json.dict("rate_limit"), rl.bool("limit_reached") == true { note = "Limit reached" }
        var resets: BankedResets?
        if let credits = json.dict("rate_limit_reset_credits"), let count = credits.int("available_count"), count >= 0 {
            resets = BankedResets(available: count, applicable: credits.int("applicable_available_count").flatMap { $0 >= 0 ? $0 : nil })
        }
        return UsageSnapshot(provider: .codex, windows: windows, planName: plan, accountLabel: email, extraUsage: extra, note: note, bankedResets: resets)
    }

    private func window(_ d: JSON?, idPrefix: String) -> UsageWindow? {
        guard let d, let pct = d.double("used_percent") else { return nil }
        let length = d.double("limit_window_seconds") ?? 0
        var reset: Date?
        if let at = d.double("reset_at") { reset = Date(timeIntervalSince1970: at) }
        else if let after = d.double("reset_after_seconds") { reset = Date().addingTimeInterval(after) }
        let label = length > 0 ? Format.duration(length) : "window"
        return UsageWindow(id: idPrefix + label, label: label, percent: pct, resetsAt: reset,
                           windowDuration: length > 0 ? length : nil)
    }

    private func planName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "free": return "Free"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise", "edu": return raw.capitalized
        default: return raw.capitalized
        }
    }
}
