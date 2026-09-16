import Foundation

/// Cursor: reads the session token from Cursor's local state database and queries the
/// same usage-summary endpoint the Cursor dashboard uses.
struct CursorProvider: UsageProvider {
    let id = ProviderID.cursor

    private var dbPath: String {
        Files.path("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func fetch() async throws -> UsageSnapshot {
        guard Files.exists(dbPath) else {
            throw ProviderError(.notConfigured, ProviderID.cursor.howToConfigure)
        }
        let db = try SQLiteDB(copyOf: dbPath)
        guard let token = try db.scalar("select value from ItemTable where key='cursorAuth/accessToken'"), !token.isEmpty else {
            throw ProviderError(.notConfigured, "Cursor is not signed in.")
        }
        let membership = try db.scalar("select value from ItemTable where key='cursorAuth/stripeMembershipType'")
        let email = try db.scalar("select value from ItemTable where key='cursorAuth/cachedEmail'")

        guard let sub = jwtClaims(token)?.string("sub") else {
            throw ProviderError(.parse, "Could not decode Cursor session token")
        }
        let userId = sub.split(separator: "|").last.map(String.init) ?? sub
        let cookie = "WorkosCursorSessionToken=\(userId)%3A%3A\(token)"

        let url = URL(string: "https://cursor.com/api/usage-summary")!
        let (data, resp) = try await HTTP.request(url, headers: [
            "Cookie": cookie,
            "Referer": "https://cursor.com/dashboard",
            "Origin": "https://cursor.com",
        ])
        switch resp.statusCode {
        case 200: break
        case 401, 403: throw ProviderError(.auth, "Cursor session expired — sign in again in the Cursor app")
        case 429: throw ProviderError(.rateLimited, "Cursor asked us to slow down", retryAfter: 120)
        default: throw ProviderError(.network, "Cursor returned HTTP \(resp.statusCode)")
        }
        let json = try HTTP.jsonObject(data)

        let start = Format.parseISO(json.string("billingCycleStart"))
        let end = Format.parseISO(json.string("billingCycleEnd"))
        var duration: TimeInterval?
        if let start, let end { duration = end.timeIntervalSince(start) }

        var windows: [UsageWindow] = []
        var extra: ExtraUsage?
        let unlimited = json.bool("isUnlimited") ?? false
        let individual = json.dict("individualUsage") ?? json.dict("teamUsage") ?? [:]

        if let plan = individual.dict("plan") {
            let used = plan.double("used") ?? 0
            let limit = plan.double("limit")
            var pct = plan.double("totalPercentUsed") ?? 0
            if pct == 0, let limit, limit > 0 { pct = used / limit * 100 }
            var detail: String?
            if let limit, limit > 0 {
                detail = "\(Format.money(used / 100, "USD"))/\(Format.money(limit / 100, "USD"))"
            }
            if unlimited { detail = "Unlimited" }
            windows.append(UsageWindow(id: "monthly", label: "Monthly", percent: pct, resetsAt: end,
                                       windowDuration: duration, detail: detail, hasLimit: !unlimited))
            if let auto = plan.double("autoPercentUsed"), let api = plan.double("apiPercentUsed"), (auto > 0 || api > 0) {
                windows.append(UsageWindow(id: "auto", label: "Auto", percent: auto, resetsAt: end, windowDuration: duration, isPrimary: false))
                windows.append(UsageWindow(id: "api", label: "API", percent: api, resetsAt: end, windowDuration: duration, isPrimary: false))
            }
        }
        if let od = individual.dict("onDemand"), od.bool("enabled") == true {
            extra = ExtraUsage(title: "On-demand", used: od.double("used").map { $0 / 100 },
                               limit: od.double("limit").map { $0 / 100 }, utilization: nil, currency: "USD")
        }
        guard !windows.isEmpty else { throw ProviderError(.parse, "No usage in Cursor response") }

        let plan = (json.string("membershipType") ?? membership)?.capitalized
        return UsageSnapshot(provider: .cursor, windows: windows, planName: plan, accountLabel: email, extraUsage: extra)
    }

    private func jwtClaims(_ token: String) -> JSON? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }
}
