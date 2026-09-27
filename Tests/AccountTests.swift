import Foundation

struct AccountTests {
    private func jwt(_ claims: [String: Any]) -> String {
        let body = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(body).sig"
    }

    private func writeAuth(_ dir: String, email: String, user: String, expires: Date) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let auth: [String: Any] = ["tokens": [
            "access_token": jwt(["exp": expires.timeIntervalSince1970]),
            "id_token": jwt(["email": email, "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_plan_type": "pro"]]),
            "account_id": "acct-\(user)",
        ]]
        try JSONSerialization.data(withJSONObject: auth).write(to: URL(fileURLWithPath: dir + "/auth.json"))
    }

    func testCodexRemembersAccountsAcrossLoginsAndFolders() throws {
        let home = NSTemporaryDirectory() + "usagebar-accounts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        var o = AccountDirectory.Options(home: home, vaultURL: URL(fileURLWithPath: home + "/vault.json"))
        let later = Date().addingTimeInterval(86400)

        try writeAuth(home + "/.codex", email: "work@example.com", user: "u1", expires: later)
        XCTAssertEqual(AccountDirectory.codex(o).map(\.email), ["work@example.com"])

        // `codex login` replaces auth.json: the first account stays, as a saved sign-in.
        try writeAuth(home + "/.codex", email: "home@example.com", user: "u2", expires: later)
        let switched = AccountDirectory.codex(o)
        XCTAssertEqual(switched.map(\.email), ["home@example.com", "work@example.com"])
        XCTAssertEqual(switched.map(\.source), [.standard, .saved])
        XCTAssertTrue(switched[0].id != switched[1].id)
        let perms = try FileManager.default.attributesOfItem(atPath: home + "/vault.json")[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        // A ~/.codex-* folder is found on its own; the same sign-in in two places is one account.
        try writeAuth(home + "/.codex-side", email: "side@example.com", user: "u3", expires: later)
        try writeAuth(home + "/.codex-copy", email: "home@example.com", user: "u2", expires: later)
        let found = AccountDirectory.codex(o)
        XCTAssertEqual(found.map(\.email), ["home@example.com", "side@example.com", "work@example.com"])
        XCTAssertEqual(found[1].source, .folder(home + "/.codex-side"))

        // Ignored folders drop out; forgetting a saved sign-in removes it for good.
        o.ignoredFolders = [home + "/.codex-side"]
        AccountDirectory.forget(found[1].key!, vaultURL: o.vaultURL)
        AccountDirectory.forget(switched[1].key!, vaultURL: o.vaultURL)
        XCTAssertEqual(AccountDirectory.codex(o).map(\.email), ["home@example.com"])

        // Not remembering: only what is on disk now.
        o.rememberCodex = false
        try writeAuth(home + "/.codex", email: "work@example.com", user: "u1", expires: later)
        XCTAssertEqual(AccountDirectory.codex(o).map(\.email), ["work@example.com", "home@example.com"])
        XCTAssertEqual(AccountDirectory.codex(o).first?.codex?.plan, "pro")
    }

    func testCodexWithoutSignInIsOnePlaceholderAndClaudeNamesKeychainPerFolder() throws {
        let home = NSTemporaryDirectory() + "usagebar-accounts-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let o = AccountDirectory.Options(home: home, vaultURL: URL(fileURLWithPath: home + "/vault.json"))
        let none = AccountDirectory.codex(o)
        XCTAssertEqual(none.map(\.id), ["codex"])

        XCTAssertEqual(AccountDirectory.claudeKeychainService(configDir: nil), "Claude Code-credentials")
        // Matches Claude Code: sha256 of the CLAUDE_CONFIG_DIR value, first 8 hex digits.
        XCTAssertEqual(AccountDirectory.claudeKeychainService(configDir: "/tmp/claude-work"), "Claude Code-credentials-bfc1769a")

        try FileManager.default.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: true)
        try #"{"oauthAccount":{"emailAddress":"w@example.com","accountUuid":"a2"}}"#.write(toFile: home + "/.claude-work/.claude.json", atomically: true, encoding: .utf8)
        let claude = AccountDirectory.claude(o)
        XCTAssertEqual(claude.map(\.id).first, "claude")
        XCTAssertEqual(claude.count, 2)
        XCTAssertEqual(claude.last?.email, "w@example.com")
        XCTAssertEqual(claude.last?.claudeConfigDir, home + "/.claude-work")

        let runway = Runway(sources: [
            Runway.Source(id: "codex:a", title: "Codex · work", snapshot: UsageSnapshot(provider: .codex, windows: [
                UsageWindow(id: "5h", label: "5h", percent: 100, resetsAt: Date().addingTimeInterval(600), windowDuration: 5 * 3600)])),
        ])
        XCTAssertEqual(runway.lead?.id, "codex:a/5h")
        XCTAssertEqual(runway.lead?.name, "Codex · work 5h")
    }
}
