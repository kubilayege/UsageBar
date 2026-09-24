import Foundation

/// The current account may run only the two sleep commands; no credentials are stored.
enum SleepAccess {
    private static let directory = "/private/etc/sudoers.d"
    private static let legacyRulePath = "\(directory)/usagebar"

    static func rulePath(uid: uid_t) -> String { "\(directory)/usagebar-\(uid)" }

    static func command(_ disabled: Bool) -> [String] {
        ["/usr/bin/pmset", "-b", "disablesleep", disabled ? "1" : "0"]
    }

    /// A different account's rule, symlink, or untrusted file never enables this setting.
    /// sudo checks the actual policy when the command runs; its files are not user-readable.
    static var isInstalled: Bool {
        let uid = getuid()
        guard uid != 0,
              let dir = try? FileManager.default.attributesOfItem(atPath: directory),
              dir[.type] as? FileAttributeType == .typeDirectory,
              (dir[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              let dirMode = (dir[.posixPermissions] as? NSNumber)?.uint16Value,
              dirMode & 0o022 == 0,
              let file = try? FileManager.default.attributesOfItem(atPath: rulePath(uid: uid)),
              file[.type] as? FileAttributeType == .typeRegular,
              (file[.ownerAccountID] as? NSNumber)?.uint32Value == 0,
              (file[.groupOwnerAccountID] as? NSNumber)?.uint32Value == 0,
              (file[.posixPermissions] as? NSNumber)?.uint16Value == 0o440 else { return false }
        return true
    }

    /// Numeric IDs avoid interpolating account names into either shell or sudoers syntax.
    static func rule(uid: uid_t) -> String {
        "#\(uid) ALL = (root) NOPASSWD: \(command(false).joined(separator: " ")), \(command(true).joined(separator: " "))"
    }

    static func installScript(uid: uid_t) -> String { changeScript(uid: uid, installing: true) }
    static func removeScript(uid: uid_t) -> String { changeScript(uid: uid, installing: false) }

    /// All temporary files stay in a protected, ignored directory. A kernel-managed lock
    /// serializes separate app instances, and failed validation restores the previous files.
    private static func changeScript(uid: uid_t, installing: Bool) -> String {
        let mutation = installing ? #"""
        chown root:wheel "$work/expected"
        chmod 0440 "$work/expected"
        visudo -c -f "$work/expected" >/dev/null 2>&1 || fail "The generated rule did not pass visudo."
        changed=1
        mv -fh "$work/expected" "$dest"
        """# : #"""
        if [ "$had_previous" = 1 ]; then
            changed=1
            rm -f "$dest"
        fi
        """#
        return #"""
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        LC_ALL=C; export LC_ALL
        umask 077
        fail() { echo "UsageBar: $*" >&2; exit 1; }
        dir=\#(directory)
        dest=\#(rulePath(uid: uid))
        legacy=\#(legacyRulePath)
        export dir dest legacy
        [ \#(uid) -ne 0 ] || fail "Passwordless mode is only for a regular account."
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(stat -f %u "$dir")" = 0 ] || fail "/etc/sudoers.d is missing or not owned by root."
        mode=$(stat -f %Lp "$dir")
        [ "$((0$mode & 022))" -eq 0 ] || fail "/etc/sudoers.d must not be writable by other accounts."
        [ "$((0$mode & 001))" -ne 0 ] || fail "/etc/sudoers.d must be searchable by your account so UsageBar can detect its rule."
        [ -z "$(ls -lde "$dir" | sed -n '2p')" ] || fail "/etc/sudoers.d has custom access permissions. Ask your administrator to configure sleep access."
        lock="$dir/.usagebar.lock"
        if [ -e "$lock" ] || [ -L "$lock" ]; then
            [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$(stat -f %u "$lock")" = 0 ] || fail "The sleep-access lock is unsafe."
            mode=$(stat -f %Lp "$lock")
            [ "$((0$mode & 022))" -eq 0 ] && [ -z "$(ls -lde "$lock" | sed -n '2p')" ] || fail "The sleep-access lock has unsafe permissions."
        fi
        /usr/bin/lockf -k -t 0 "$lock" /bin/sh <<'USAGEBAR_SLEEP_RULE'
        set -eu
        fail() { echo "UsageBar: $*" >&2; exit 1; }
        grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+(/private)?/etc/sudoers[.]d/?[[:space:]]*$' /private/etc/sudoers || fail "sudo is not set up to read /etc/sudoers.d."
        visudo -c >/dev/null 2>&1 || fail "The existing sudoers configuration did not pass validation. No rules were changed."
        work=$(mktemp -d "$dir/.usagebar.XXXXXX")
        changed=0
        had_previous=0
        legacy_moved=0
        committed=0
        cleanup() {
            result=$?
            trap - EXIT HUP INT TERM
            set +e
            restored=1
            if [ "$committed" = 0 ]; then
                if [ "$changed" = 1 ]; then
                    if [ "$had_previous" = 1 ]; then
                        mv -fh "$work/previous" "$dest" || restored=0
                    else
                        rm -f "$dest" || restored=0
                    fi
                fi
                if [ "$legacy_moved" = 1 ] && [ -f "$work/legacy" ]; then
                    mv -fh "$work/legacy" "$legacy" || restored=0
                fi
            fi
            if [ "$restored" = 1 ]; then
                rm -rf "$work"
            else
                echo "UsageBar: Could not restore the previous rule; its backup remains at $work." >&2
                result=1
            fi
            exit "$result"
        }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        printf '%s\n' '# Managed by UsageBar. Delete this file to revoke.' '\#(rule(uid: uid))' > "$work/expected"
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(stat -f %u "$dest")" = 0 ] || fail "The existing UsageBar rule is not a regular root-owned file."
            cmp -s "$work/expected" "$dest" || fail "The existing UsageBar rule was customized. No rules were changed."
            cp -p "$dest" "$work/previous"
            had_previous=1
        fi
        # Only migrate this account's exact old generated rule, preserving other accounts' rules.
        if [ -f "$legacy" ] && [ ! -L "$legacy" ] && [ "$(stat -f %u "$legacy")" = 0 ] && cmp -s "$work/expected" "$legacy"; then
            legacy_moved=1
            mv -fh "$legacy" "$work/legacy"
        fi
        \#(mutation)
        visudo -c >/dev/null 2>&1 || fail "The sudoers check failed. The previous rules will be restored."
        committed=1
        USAGEBAR_SLEEP_RULE
        """#
    }

    static func failureReason(_ osascriptError: String) -> String? {
        guard let start = osascriptError.range(of: "UsageBar: ", options: .backwards) else { return nil }
        let message = osascriptError[start.upperBound...].replacingOccurrences(of: #"\s*\(-?\d+\)\s*$"#, with: "", options: .regularExpression)
        return message.isEmpty ? nil : message
    }

    static func runAsAdministrator(_ script: String, prompt: String) -> Shell.Result? {
        Shell.runResult("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            script, prompt,
        ], timeout: 120)
    }
}
