import Foundation
import CryptoKit

/// One signed-in identity whose limits UsageBar tracks. Providers without multi-account
/// support have exactly one, with a nil key, so their ids stay the plain provider name.
struct Account: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// The CLI's default location (`~/.claude`, `~/.codex`, …).
        case standard
        /// Another config folder: `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
        case folder(String)
        /// A Codex sign-in UsageBar remembered after the CLI switched to another account.
        case saved
    }

    var provider: ProviderID
    var key: String?
    var source: Source
    var email: String?
    var nickname: String?
    var claudeConfigDir: String?
    var codex: CodexCredential?

    var id: String { key.map { "\(provider.rawValue):\($0)" } ?? provider.rawValue }

    static func == (a: Account, b: Account) -> Bool {
        a.id == b.id && a.source == b.source && a.email == b.email && a.nickname == b.nickname
            && a.claudeConfigDir == b.claudeConfigDir && a.codex?.accessToken == b.codex?.accessToken
    }

    func hash(into h: inout Hasher) { h.combine(id) }

    var sourceDescription: String {
        switch source {
        case .standard: return provider == .claude ? "~/.claude" : provider == .codex ? "~/.codex" : "Default"
        case .folder(let path): return AccountDirectory.abbreviate(path)
        case .saved: return "Saved sign-in"
        }
    }
}

/// The ChatGPT sign-in Codex keeps in `auth.json`. UsageBar keeps only the access token,
/// never the refresh token, so a saved account stops working when that token expires.
struct CodexCredential: Codable, Hashable, Sendable {
    var key: String
    var accessToken: String
    var accountID: String?
    var email: String?
    var plan: String?
    var expiresAt: Date?

    var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }

    static func parse(_ auth: JSON) -> CodexCredential? {
        guard let tokens = auth.dict("tokens"), let access = tokens.string("access_token"), !access.isEmpty else { return nil }
        let id = tokens.string("id_token").flatMap(JWT.claims) ?? [:]
        let claims = id.dict("https://api.openai.com/auth") ?? [:]
        let accountID = tokens.string("account_id") ?? claims.string("chatgpt_account_id")
        let email = id.string("email")
        let user = claims.string("chatgpt_user_id") ?? claims.string("user_id") ?? email ?? ""
        let exp = JWT.claims(access)?.double("exp").map { Date(timeIntervalSince1970: $0) }
        return CodexCredential(key: AccountDirectory.shortHash("\(user)|\(accountID ?? "")"), accessToken: access,
                               accountID: accountID, email: email, plan: claims.string("chatgpt_plan_type"), expiresAt: exp)
    }
}

enum JWT {
    static func claims(_ token: String) -> JSON? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let data = Data(base64Encoded: s) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }
}

/// Finds every Claude and Codex account on this Mac, and remembers Codex sign-ins
/// so an account keeps its meters after `codex login` switches to another one.
enum AccountDirectory {
    struct Options: Sendable {
        var claudeFolders: [String] = []
        var codexFolders: [String] = []
        var ignoredFolders: Set<String> = []
        var rememberCodex = true
        var nicknames: [String: String] = [:]
        var home = Files.home
        var vaultURL = Files.appSupport.appendingPathComponent("codex-accounts.json")
    }

    static func discover(_ o: Options) -> [ProviderID: [Account]] {
        var out: [ProviderID: [Account]] = [:]
        out[.claude] = claude(o)
        out[.codex] = codex(o)
        for id in ProviderID.allCases where out[id] == nil { out[id] = [Account(provider: id, key: nil, source: .standard)] }
        for (id, list) in out {
            out[id] = list.map { a in var a = a; a.nickname = o.nicknames[a.id].flatMap { $0.isEmpty ? nil : $0 }; return a }
        }
        return out
    }

    // MARK: Claude

    /// Claude accounts are config folders: tokens expire within hours and only the CLI refreshes them.
    static func claude(_ o: Options) -> [Account] {
        let standardDir = (o.home as NSString).appendingPathComponent(".claude")
        var accounts = [Account(provider: .claude, key: nil, source: .standard,
                                email: claudeEmail(configJSON: (o.home as NSString).appendingPathComponent(".claude.json")))]
        var seen: Set<String> = [claudeAccountUUID(configJSON: (o.home as NSString).appendingPathComponent(".claude.json")) ?? "standard"]
        let folders = unique(o.claudeFolders + autoFolders(prefix: ".claude", marker: ".claude.json", home: o.home))
        for dir in folders where dir != standardDir && !o.ignoredFolders.contains(dir) {
            let json = (dir as NSString).appendingPathComponent(".claude.json")
            if let uuid = claudeAccountUUID(configJSON: json) {
                guard seen.insert(uuid).inserted else { continue }
            }
            accounts.append(Account(provider: .claude, key: shortHash(dir), source: .folder(dir),
                                    email: claudeEmail(configJSON: json), claudeConfigDir: dir))
        }
        return accounts
    }

    /// Claude Code names the keychain item after the config folder when `CLAUDE_CONFIG_DIR` is set.
    static func claudeKeychainService(configDir: String?) -> String {
        guard let dir = configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    private static func claudeEmail(configJSON: String) -> String? {
        Files.readJSON(configJSON)?.dict("oauthAccount")?.string("emailAddress")
    }

    private static func claudeAccountUUID(configJSON: String) -> String? {
        Files.readJSON(configJSON)?.dict("oauthAccount")?.string("accountUuid")
    }

    // MARK: Codex

    /// Codex accounts are identities: every auth.json UsageBar can see, plus remembered sign-ins.
    static func codex(_ o: Options) -> [Account] {
        let standardDir = (o.home as NSString).appendingPathComponent(".codex")
        var live: [(Account.Source, CodexCredential)] = []
        if let auth = Files.readJSON((standardDir as NSString).appendingPathComponent("auth.json")), let c = CodexCredential.parse(auth) {
            live.append((.standard, c))
        }
        let folders = unique(o.codexFolders + autoFolders(prefix: ".codex", marker: "auth.json", home: o.home))
        for dir in folders where dir != standardDir && !o.ignoredFolders.contains(dir) {
            if let auth = Files.readJSON((dir as NSString).appendingPathComponent("auth.json")), let c = CodexCredential.parse(auth) {
                live.append((.folder(dir), c))
            }
        }

        var saved = o.rememberCodex ? loadVault(o.vaultURL) : []
        if o.rememberCodex {
            var changed = false
            for (_, c) in live {
                if let i = saved.firstIndex(where: { $0.key == c.key }) {
                    if saved[i] != c, (c.expiresAt ?? .distantFuture) >= (saved[i].expiresAt ?? .distantPast) { saved[i] = c; changed = true }
                } else {
                    saved.append(c); changed = true
                }
            }
            if changed { saveVault(saved, to: o.vaultURL) }
        }

        var accounts: [Account] = []
        for (source, c) in live {
            if let i = accounts.firstIndex(where: { $0.key == c.key }) {
                // The same sign-in in two folders: keep the first source, use the token that lasts longest.
                if let old = accounts[i].codex, (c.expiresAt ?? .distantPast) > (old.expiresAt ?? .distantPast) { accounts[i].codex = c }
                continue
            }
            accounts.append(Account(provider: .codex, key: c.key, source: source, email: c.email, codex: c))
        }
        for c in saved where !accounts.contains(where: { $0.key == c.key }) {
            accounts.append(Account(provider: .codex, key: c.key, source: .saved, email: c.email, codex: c))
        }
        // Nothing signed in: one placeholder so the card can explain how to set Codex up.
        return accounts.isEmpty ? [Account(provider: .codex, key: nil, source: .standard)] : accounts
    }

    static func loadVault(_ url: URL) -> [CodexCredential] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([CodexCredential].self, from: data)) ?? []
    }

    static func saveVault(_ list: [CodexCredential], to url: URL) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        guard let data = try? enc.encode(list) else { return }
        // Same protection Codex gives auth.json: readable by this user only.
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    static func forget(_ key: String, vaultURL: URL = Files.appSupport.appendingPathComponent("codex-accounts.json")) {
        saveVault(loadVault(vaultURL).filter { $0.key != key }, to: vaultURL)
    }

    static func clearVault(_ url: URL = Files.appSupport.appendingPathComponent("codex-accounts.json")) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Helpers

    /// Home folders such as `~/.codex-work` or `~/.claude-personal` that hold a config.
    static func autoFolders(prefix: String, marker: String, home: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0.hasPrefix(prefix) && $0 != prefix }
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { Files.exists(($0 as NSString).appendingPathComponent(marker)) }
            .sorted()
    }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func abbreviate(_ path: String) -> String {
        let home = Files.home
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func shortHash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.map(normalize).filter { seen.insert($0).inserted }
    }
}
