import Foundation

/// Antigravity (experimental): talks to the local language server the Antigravity IDE
/// launches, and reads the per-model quota it reports. Only works while Antigravity runs.
struct AntigravityProvider: UsageProvider {
    let id = ProviderID.antigravity

    private struct Server { var pid: Int32; var csrf: String?; var ports: [Int] }

    func fetch() async throws -> UsageSnapshot {
        guard let server = discover() else {
            throw ProviderError(.notConfigured, "Antigravity is not running (its language server was not found).")
        }
        guard !server.ports.isEmpty else {
            throw ProviderError(.unavailable, "Antigravity language server has no listening port yet.")
        }
        var headers = ["Content-Type": "application/json", "Connect-Protocol-Version": "1"]
        if let csrf = server.csrf { headers["X-Codeium-Csrf-Token"] = csrf }
        let body = HTTP.jsonBody(["metadata": [
            "ideName": "antigravity", "ideVersion": "1.0.0",
            "extensionName": "antigravity", "extensionVersion": "1.0.0",
        ]])

        var lastError = "No response from Antigravity"
        for port in server.ports {
            for scheme in ["https", "http"] {
                let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
                guard let (data, resp) = try? await HTTP.request(url, method: "POST", headers: headers, body: body, session: HTTP.insecureLocal) else { continue }
                guard resp.statusCode == 200, let json = try? HTTP.jsonObject(data) else {
                    lastError = "Antigravity replied HTTP \(resp.statusCode) on port \(port)"
                    continue
                }
                var quotas: [(String, Double, Date?)] = []
                collectQuotas(json, label: nil, into: &quotas)
                guard !quotas.isEmpty else {
                    lastError = "Antigravity status has no quota info"
                    continue
                }
                var seen = Set<String>()
                var windows: [UsageWindow] = []
                for (label, remaining, reset) in quotas where !seen.contains(label) {
                    seen.insert(label)
                    windows.append(UsageWindow(id: label, label: label, percent: (1 - remaining) * 100, resetsAt: reset,
                                               windowDuration: nil, isPrimary: windows.count < 3))
                }
                let user = json.dict("userStatus")
                let plan = user?.dict("planStatus")?.string("planName") ?? user?.string("planName")
                let email = user?.string("email") ?? user?.string("name")
                return UsageSnapshot(provider: .antigravity, windows: windows, planName: plan, accountLabel: email, note: "Experimental")
            }
        }
        throw ProviderError(.unavailable, lastError)
    }

    private func discover() -> Server? {
        guard let ps = Shell.run("/bin/ps", ["-axo", "pid=,args="]) else { return nil }
        for line in ps.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.lowercased().contains("antigravity"), s.contains("language_server") else { continue }
            guard let pidStr = s.split(separator: " ").first, let pid = Int32(pidStr) else { continue }
            var csrf: String?
            if let r = s.range(of: #"--csrf_token[= ]([A-Za-z0-9\-_]+)"#, options: .regularExpression) {
                let match = String(s[r])
                csrf = match.split(whereSeparator: { $0 == "=" || $0 == " " }).last.map(String.init)
            }
            let ports = listeningPorts(pid: pid)
            return Server(pid: pid, csrf: csrf, ports: ports)
        }
        return nil
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

    private func collectQuotas(_ node: Any, label: String?, into out: inout [(String, Double, Date?)]) {
        if let dict = node as? JSON {
            if let q = dict.dict("quotaInfo"), let remaining = q.double("remainingFraction") {
                let name = dict.string("label") ?? dict.string("modelName") ?? dict.string("displayName") ?? dict.string("model") ?? label ?? "Quota"
                out.append((name, remaining, Format.parseISO(q.string("resetTime"))))
            }
            for (k, v) in dict { collectQuotas(v, label: dict.string("label") ?? dict.string("displayName") ?? k, into: &out) }
        } else if let arr = node as? [Any] {
            for v in arr { collectQuotas(v, label: label, into: &out) }
        }
    }
}
