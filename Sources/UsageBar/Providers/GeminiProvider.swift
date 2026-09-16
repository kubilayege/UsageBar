import Foundation

/// Gemini CLI (experimental): uses the CLI's cached Google OAuth token to query the
/// Code Assist quota endpoint. Requires having signed in with `gemini` at least once.
struct GeminiProvider: UsageProvider {
    let id = ProviderID.gemini

    /// OAuth client used only to refresh the Gemini CLI's own token. Not shipped in this source:
    /// set GEMINI_OAUTH_CLIENT_ID / GEMINI_OAUTH_CLIENT_SECRET, or install the Gemini CLI, whose
    /// bundled `oauth2.js` declares them.
    static func oauthClient() -> (id: String, secret: String)? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["GEMINI_OAUTH_CLIENT_ID"], let secret = env["GEMINI_OAUTH_CLIENT_SECRET"], !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        let home = Files.home
        var roots = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules", home + "/.npm-global/lib/node_modules",
                     home + "/.bun/install/global/node_modules"]
        for versions in [home + "/.nvm/versions/node", home + "/.volta/tools/image/node"] {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: versions)) ?? [] {
                roots.append(versions + "/" + entry + "/lib/node_modules")
            }
        }
        for root in roots {
            for package in ["@google/gemini-cli/node_modules/@google/gemini-cli-core", "@google/gemini-cli-core"] {
                let file = root + "/" + package + "/dist/src/code_assist/oauth2.js"
                guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                func value(_ name: String) -> String? {
                    guard let match = source.range(of: name + #"\s*=\s*['"]([^'"]+)['"]"#, options: .regularExpression) else { return nil }
                    return source[match].split(whereSeparator: { $0 == "'" || $0 == "\"" }).dropFirst().first.map(String.init)
                }
                if let id = value("OAUTH_CLIENT_ID"), let secret = value("OAUTH_CLIENT_SECRET") { return (id, secret) }
            }
        }
        return nil
    }

    func fetch() async throws -> UsageSnapshot {
        let path = Files.path(".gemini/oauth_creds.json")
        guard let creds = Files.readJSON(path) else {
            throw ProviderError(.notConfigured, ProviderID.gemini.howToConfigure)
        }
        var token = creds.string("access_token") ?? ""
        let expiry = creds.double("expiry_date").map { Date(timeIntervalSince1970: $0 / 1000) }
        if token.isEmpty || (expiry ?? .distantFuture) < Date().addingTimeInterval(60) {
            guard let refresh = creds.string("refresh_token") else {
                throw ProviderError(.auth, "Gemini token expired — run `gemini` to sign in again")
            }
            token = try await refreshToken(refresh)
        }
        let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]

        // Discover the Code Assist project + tier.
        var project: String?
        var tier: String?
        let loadURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
        let loadBody = HTTP.jsonBody(["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]])
        if let (d, r) = try? await HTTP.request(loadURL, method: "POST", headers: headers, body: loadBody), r.statusCode == 200,
           let j = try? HTTP.jsonObject(d) {
            if let p = j.string("cloudaicompanionProject") { project = p }
            else if let p = j.dict("cloudaicompanionProject")?.string("id") { project = p }
            tier = j.dict("currentTier")?.string("name") ?? j.dict("currentTier")?.string("id")
        }

        let quotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        var body: JSON = [:]
        if let project { body["project"] = project }
        let (data, resp) = try await HTTP.request(quotaURL, method: "POST", headers: headers, body: HTTP.jsonBody(body))
        switch resp.statusCode {
        case 200: break
        case 401, 403: throw ProviderError(.auth, "Google rejected the Gemini token (\(resp.statusCode))")
        default: throw ProviderError(.network, "Gemini quota endpoint returned HTTP \(resp.statusCode)")
        }
        let json = try HTTP.jsonObject(data)

        var windows: [UsageWindow] = []
        for case let b as JSON in json.array("buckets") ?? [] {
            guard let remaining = b.double("remainingFraction") else { continue }
            let model = b.string("modelId") ?? b.string("model") ?? "Quota"
            let label = model.replacingOccurrences(of: "gemini-", with: "").replacingOccurrences(of: "-", with: " ")
            windows.append(UsageWindow(id: model, label: label.capitalized, percent: (1 - remaining) * 100,
                                       resetsAt: Format.parseISO(b.string("resetTime")), windowDuration: 86400,
                                       isPrimary: windows.count < 2))
        }
        guard !windows.isEmpty else {
            throw ProviderError(.unavailable, "Gemini returned no quota buckets")
        }
        return UsageSnapshot(provider: .gemini, windows: windows, planName: tier?.capitalized, accountLabel: nil,
                             note: "Experimental")
    }

    private func refreshToken(_ refresh: String) async throws -> String {
        guard let client = Self.oauthClient() else {
            throw ProviderError(.auth, "Gemini token expired. Run `gemini` to sign in again, or install the Gemini CLI so UsageBar can refresh the token.")
        }
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        let form = "client_id=\(client.id)&client_secret=\(client.secret)&refresh_token=\(refresh)&grant_type=refresh_token"
        let (data, resp) = try await HTTP.request(url, method: "POST",
                                                  headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                  body: form.data(using: .utf8))
        guard resp.statusCode == 200, let json = try? HTTP.jsonObject(data), let token = json.string("access_token") else {
            throw ProviderError(.auth, "Gemini token refresh failed — run `gemini` to sign in again")
        }
        return token
    }
}
