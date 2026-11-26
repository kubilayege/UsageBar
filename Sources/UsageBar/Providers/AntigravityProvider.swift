import Foundation

/// Antigravity (experimental): talks to the local language server the Antigravity app
/// launches, and reads the per-model quota it reports. Only works while Antigravity runs.
struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity

    private struct Endpoint: Equatable { var scheme: String; var port: Int }
    private struct Server { var csrf: String?; var endpoints: [Endpoint] }

    func fetch() async throws -> UsageSnapshot {
        let servers = discover()
        guard !servers.isEmpty else {
            throw ProviderError(.notConfigured, "Antigravity is not running (its language server was not found).")
        }
        let body = HTTP.jsonBody(["metadata": [
            "ideName": "antigravity", "ideVersion": "1.0.0",
            "extensionName": "antigravity", "extensionVersion": "1.0.0",
        ]])

        var lastError = "Antigravity language server has no listening port yet."
        for server in servers {
            var headers = ["Content-Type": "application/json", "Connect-Protocol-Version": "1"]
            if let csrf = server.csrf { headers["X-Codeium-Csrf-Token"] = csrf }
            for endpoint in server.endpoints {
                let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
                guard let (data, resp) = try? await HTTP.request(url, method: "POST", headers: headers, body: body, session: HTTP.insecureLocal) else { continue }
                guard resp.statusCode == 200, let json = try? HTTP.jsonObject(data) else {
                    lastError = "Antigravity replied HTTP \(resp.statusCode) on port \(endpoint.port)"
                    continue
                }
                let windows = Self.windows(from: json)
                guard !windows.isEmpty else {
                    lastError = "Antigravity status has no quota info"
                    continue
                }
                let user = json.dict("userStatus")
                let tier = user?.dict("userTier")
                let planStatus = user?.dict("planStatus")
                let plan = tier?.string("name") ?? tier?.string("description")
                    ?? planStatus?.dict("planInfo")?.string("planName") ?? planStatus?.string("planName") ?? user?.string("planName")
                let email = user?.string("email") ?? user?.string("name")
                return UsageSnapshot(provider: .antigravity, windows: windows, planName: plan, accountLabel: email, note: "Experimental")
            }
        }
        throw ProviderError(.unavailable, lastError)
    }

    // MARK: Quota parsing

    /// Thinking levels Antigravity appends to a model label, e.g. "Gemini 4 Neon (High)".
    private static let thinkingLevels: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "extra high", "max"]

    /// One window per model. Antigravity lists every thinking level of a model as its own entry
    /// ("Gemini 4 Neon (Low)" … "(XHigh)") with the same quota, so they fold into one row that
    /// shows the most used level. The three most used models are primary; ties keep the
    /// order Antigravity recommends them in.
    static func windows(from json: JSON) -> [UsageWindow] {
        var quotas: [(label: String, remaining: Double, reset: Date?)] = []
        collectQuotas(json, label: nil, into: &quotas)

        var families: [String] = []
        collectFamilies(json, into: &families)
        // Longest names first so "Gemini 4 Neon Pro" never matches as "Gemini 4 Neon".
        families.sort { $0.count > $1.count }

        var order: [String] = []
        var grouped: [String: (used: Double, reset: Date?)] = [:]
        var seen = Set<String>()
        for q in quotas where seen.insert(q.label).inserted {
            let name = family(of: q.label, known: families)
            let used = min(100, max(0, (1 - q.remaining) * 100))
            guard let current = grouped[name] else {
                order.append(name)
                grouped[name] = (used, q.reset)
                continue
            }
            if used > current.used {
                grouped[name] = (used, q.reset ?? current.reset)
            } else if used == current.used, let reset = q.reset, current.reset.map({ reset < $0 }) ?? true {
                grouped[name] = (used, reset)
            }
        }

        let ranked = order.enumerated().sorted { a, b in
            let ua = grouped[a.element]!.used, ub = grouped[b.element]!.used
            return ua != ub ? ua > ub : a.offset < b.offset
        }
        let primary = Set(ranked.prefix(3).map(\.element))
        return order.map { name in
            let g = grouped[name]!
            return UsageWindow(id: name, label: name, percent: g.used, resetsAt: g.reset,
                               windowDuration: nil, isPrimary: primary.contains(name))
        }
    }

    private static func family(of label: String, known: [String]) -> String {
        if let match = known.first(where: { label == $0 || label.hasPrefix($0 + " (") }) { return match }
        guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else { return label }
        let level = label[open.upperBound..<label.index(before: label.endIndex)].lowercased()
        return thinkingLevels.contains(level) ? String(label[..<open.lowerBound]) : label
    }

    /// Model names from `groupedModels`, which maps each model id to its display name.
    private static func collectFamilies(_ node: Any, into out: inout [String]) {
        if let dict = node as? JSON {
            if let groups = dict.dict("groupedModels") {
                for case let group as JSON in groups.values {
                    if let name = group.string("displayName"), !out.contains(name) { out.append(name) }
                }
            }
            for (key, value) in dict where key != "groupedModels" { collectFamilies(value, into: &out) }
        } else if let arr = node as? [Any] {
            for v in arr { collectFamilies(v, into: &out) }
        }
    }

    private static func collectQuotas(_ node: Any, label: String?, into out: inout [(label: String, remaining: Double, reset: Date?)]) {
        if let dict = node as? JSON {
            if let q = dict.dict("quotaInfo") {
                let name = dict.string("label") ?? dict.string("modelName") ?? dict.string("displayName") ?? dict.string("model") ?? label ?? "Quota"
                // Proto3 JSON drops zero values, so an exhausted model has no remainingFraction.
                out.append((name, q.double("remainingFraction") ?? 0, Format.parseISO(q.string("resetTime"))))
            }
            // Visit keys in a stable order; dictionary order would shuffle the rows every refresh.
            for key in dict.keys.sorted() where key != "quotaInfo" {
                collectQuotas(dict[key]!, label: dict.string("label") ?? dict.string("displayName") ?? key, into: &out)
            }
        } else if let arr = node as? [Any] {
            for v in arr { collectQuotas(v, label: label, into: &out) }
        }
    }

    // MARK: Discovery

    private func discover() -> [Server] {
        var servers = daemonServers()
        // Antigravity IDE (and 1.x) put the token on the language server's command line.
        for (pid, s) in ProcessList.commandLines() {
            guard s.lowercased().contains("antigravity"), s.contains("language_server") else { continue }
            guard let r = s.range(of: #"--csrf_token[= ]([A-Za-z0-9\-_]+)"#, options: .regularExpression) else { continue }
            let csrf = String(s[r]).split(whereSeparator: { $0 == "=" || $0 == " " }).last.map(String.init)
            let endpoints = listeningPorts(pid: pid).flatMap { [Endpoint(scheme: "https", port: $0), Endpoint(scheme: "http", port: $0)] }
            servers.append(Server(csrf: csrf, endpoints: endpoints))
        }
        return servers
    }

    /// Antigravity 2.x passes the CSRF token through the environment and writes it, with the
    /// server's ports, to `~/.gemini/antigravity/daemon/hub_<port>.json`.
    private func daemonServers() -> [Server] {
        var servers: [Server] = []
        for app in ["antigravity", "antigravity-cli"] {
            let dir = Files.path(".gemini/\(app)/daemon")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") {
                guard let info = Files.readJSON((dir as NSString).appendingPathComponent(name)),
                      let pid = info.int("pid"), pid > 0, kill(pid_t(pid), 0) == 0 else { continue }
                var endpoints: [Endpoint] = []
                if let port = info.int("httpPort") { endpoints.append(Endpoint(scheme: "http", port: port)) }
                if let port = info.int("httpsPort") { endpoints.append(Endpoint(scheme: "https", port: port)) }
                if !endpoints.isEmpty { servers.append(Server(csrf: info.string("csrfToken"), endpoints: endpoints)) }
            }
        }
        return servers
    }

    private func listeningPorts(pid: Int32) -> [Int] {
        guard let out = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"]) else { return [] }
        var ports: [Int] = []
        for line in out.split(separator: "\n").dropFirst() {
            guard let range = line.range(of: #":(\d+) \(LISTEN\)"#, options: .regularExpression) else { continue }
            let frag = line[range].dropFirst().split(separator: " ").first ?? ""
            if let p = Int(frag), !ports.contains(p) { ports.append(p) }
        }
        return ports
    }
}
