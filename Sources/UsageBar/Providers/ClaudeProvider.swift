import Foundation

/// Claude Code: reads the OAuth token Claude Code stores in the login keychain and
/// queries Anthropic's OAuth usage endpoint (the same one the CLI uses for /usage).
struct ClaudeProvider: UsageProvider {
    let id = ProviderID.claude

    private struct Creds {
        var token: String
        var expiresAt: Date?
        var subscription: String?
        var tier: String?
    }

    private func loadCreds() throws -> Creds {
        var json: JSON?
        if let s = Keychain.genericPassword(service: "Claude Code-credentials"),
           let data = s.data(using: .utf8) {
            json = try? JSONSerialization.jsonObject(with: data) as? JSON
        }
        if json == nil {
            json = Files.readJSON(Files.path(".claude/.credentials.json"))
        }
        guard let oauth = json?.dict("claudeAiOauth"), let token = oauth.string("accessToken"), !token.isEmpty else {
            throw ProviderError(.notConfigured, ProviderID.claude.howToConfigure)
        }
        let expires = oauth.double("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(token: token, expiresAt: expires,
                     subscription: oauth.string("subscriptionType"), tier: oauth.string("rateLimitTier"))
    }

    func fetch() async throws -> UsageSnapshot {
        let creds = try loadCreds()
        if let exp = creds.expiresAt, exp < Date().addingTimeInterval(-60) {
            throw ProviderError(.auth, "Claude token expired — run `claude` once to refresh it")
        }
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let (data, resp) = try await HTTP.request(url, headers: [
            "Authorization": "Bearer \(creds.token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        ])
        switch resp.statusCode {
        case 200: break
        case 401, 403: throw ProviderError(.auth, "Claude rejected the token (\(resp.statusCode)) — run `claude` to sign in again")
        case 429:
            let retry = resp.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 120
            throw ProviderError(.rateLimited, "Anthropic asked us to slow down", retryAfter: max(60, retry))
        default: throw ProviderError(.network, "Anthropic returned HTTP \(resp.statusCode)")
        }
        let json = try HTTP.jsonObject(data)

        var windows: [UsageWindow] = []
        if let w = window(json.dict("five_hour"), id: "5h", label: "5h", duration: 5 * 3600) { windows.append(w) }
        if let w = window(json.dict("seven_day"), id: "7d", label: "7d", duration: 7 * 86400) { windows.append(w) }
        for (key, label) in [("seven_day_opus", "Opus 7d"), ("seven_day_sonnet", "Sonnet 7d"), ("seven_day_oauth_apps", "Apps 7d")] {
            if var w = window(json.dict(key), id: key, label: label, duration: 7 * 86400) {
                w.isPrimary = false
                windows.append(w)
            }
        }
        guard !windows.isEmpty else { throw ProviderError(.parse, "No usage windows in response") }

        var extra: ExtraUsage?
        if let eu = json.dict("extra_usage"), eu.bool("is_enabled") == true {
            let places = eu.int("decimal_places") ?? 2
            let scale = pow(10.0, Double(places))
            extra = ExtraUsage(
                title: "Extra",
                used: eu.double("used_credits").map { $0 / scale },
                limit: eu.double("monthly_limit").map { $0 / scale },
                utilization: eu.double("utilization"),
                currency: eu.string("currency")
            )
        }

        var plan: String?
        if let tier = creds.tier, !tier.isEmpty, tier.lowercased() != "default" {
            plan = tier.replacingOccurrences(of: "default_", with: "").replacingOccurrences(of: "claude_", with: "")
                .replacingOccurrences(of: "_", with: " ").capitalized
        } else if let sub = creds.subscription {
            plan = sub.capitalized
        }

        return UsageSnapshot(provider: .claude, windows: windows, planName: plan, accountLabel: nil, extraUsage: extra)
    }

    private func window(_ d: JSON?, id: String, label: String, duration: TimeInterval) -> UsageWindow? {
        guard let d, let pct = d.double("utilization") else { return nil }
        var detail: String?
        if let locked = d.string("locked_reason"), !locked.isEmpty { detail = locked }
        return UsageWindow(id: id, label: label, percent: pct,
                           resetsAt: Format.parseISO(d.string("resets_at")),
                           windowDuration: duration, detail: detail)
    }
}
