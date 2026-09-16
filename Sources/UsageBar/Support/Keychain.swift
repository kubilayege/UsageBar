import Foundation
import Security

enum Keychain {
    /// Reads a generic password. Tries the `security` CLI first (Claude Code writes its
    /// credentials through it, so the ACL usually already allows it without a prompt),
    /// then falls back to the Security framework.
    static func genericPassword(service: String) -> String? {
        if let s = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"], timeout: 10)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
