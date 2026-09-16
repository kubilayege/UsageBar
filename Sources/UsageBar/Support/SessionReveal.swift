import AppKit
import Foundation

/// Reopens an agent session in a terminal (`claude --resume <id>` etc.). When the agent is still
/// running somewhere, brings that terminal or IDE window to the front instead of starting a second one.
enum SessionReveal {
    private struct Proc { let pid: pid_t; let ppid: pid_t; let tty: String?; let comm: String }
    private struct Host { let agentPid: pid_t; let tty: String?; let bundlePath: String?; let appPid: pid_t? }

    /// Default button action: jump to the running agent if there is one, otherwise resume in a new terminal.
    static func reveal(_ session: LiveSession) {
        DispatchQueue.global(qos: .userInitiated).async {
            let host = locate(session)
            DispatchQueue.main.async {
                if let host, activate(host) { selectTab(host) } else { resumeInTerminal(session) }
            }
        }
    }

    /// Always opens a new terminal window in the session's folder and resumes the session there.
    static func resumeInTerminal(_ session: LiveSession) {
        openTerminal(at: session.cwd, running: resumeCommand(session))
    }

    static func copyResumeCommand(_ session: LiveSession) {
        let line = shellLine(cwd: session.cwd, command: resumeCommand(session))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    /// The CLI invocation that reopens this session; must run from the session's working directory.
    static func resumeCommand(_ session: LiveSession) -> String? {
        guard let id = sessionKey(session) else { return nil }
        switch session.provider {
        case .claude: return "claude --resume \(id)"
        case .codex: return "codex resume \(id)"
        case .opencode: return "opencode --session \(id)"
        default: return nil
        }
    }

    /// Debug: what the button would do for this session (`UsageBar --reveal-sessions`).
    static func describe(_ session: LiveSession) -> String {
        let cmd = shellLine(cwd: session.cwd, command: resumeCommand(session))
        guard let h = locate(session) else { return "not running → new terminal: \(cmd)" }
        return "running: pid \(h.agentPid) tty \(h.tty ?? "-") host \(h.bundlePath ?? "?") (pid \(h.appPid.map(String.init) ?? "-"))\n      resume: \(cmd)"
    }

    // MARK: Locate the agent process and the app that hosts it

    private static func locate(_ session: LiveSession) -> Host? {
        let table = processTable()
        let candidates = agentPids(for: session.provider, sessionKey: sessionKey(session))
        guard !candidates.isEmpty else { return nil }
        let want = Set([normalize(session.cwd), resolve(session.cwd)])
        let matching = cwds(of: candidates.map(\.pid)).filter { want.contains($0.value) || want.contains(resolve($0.value)) }.map(\.key)
        guard !matching.isEmpty else { return nil }
        // Several agents can share a folder (e.g. headless `claude -p` runners next to the interactive TUI).
        // Rank: process that names this session id, then interactive ones, then anything on a tty, then helpers.
        let exact = Set(candidates.filter(\.exact).map(\.pid))
        let other = Set(candidates.filter(\.namesOtherSession).map(\.pid))
        let headless = Set(candidates.filter(\.headless).map(\.pid))
        // A process that names a different session id, or a headless runner that doesn't name ours, is not this session.
        let plausible = matching.filter { exact.contains($0) || (!other.contains($0) && !headless.contains($0)) }
        guard !plausible.isEmpty else { return nil }
        func rank(_ pid: pid_t) -> Int { (exact.contains(pid) ? 0 : 2) + (table[pid]?.tty == nil ? 1 : 0) }
        let agent = plausible.min { rank($0) < rank($1) }!

        // Walk up the parent chain to the outermost .app bundle (Terminal, Ghostty, VS Code, T3 Code, ...).
        var pid = agent
        var bundlePath: String?, appPid: pid_t?
        var hops = 0
        while let p = table[pid], hops < 32 {
            if let r = p.comm.range(of: ".app/") {
                bundlePath = String(p.comm[..<r.lowerBound]) + ".app"
                appPid = p.pid
                // Keep climbing while the parent is inside the same bundle so we land on the main process.
                if let parent = table[p.ppid], parent.comm.hasPrefix(bundlePath! + "/") { pid = p.ppid; hops += 1; continue }
                break
            }
            if p.ppid <= 1 { break }
            pid = p.ppid; hops += 1
        }
        return Host(agentPid: agent, tty: table[agent]?.tty, bundlePath: bundlePath, appPid: appPid)
    }

    private static func processTable() -> [pid_t: Proc] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]) else { return [:] }
        var table: [pid_t: Proc] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            let tty = parts[2] == "??" ? nil : String(parts[2])
            table[pid] = Proc(pid: pid, ppid: ppid, tty: tty, comm: parts[3].trimmingCharacters(in: .whitespaces))
        }
        return table
    }

    /// The session's UUID as it appears in `--session-id` / `--resume` arguments, when we know it.
    private static func sessionKey(_ session: LiveSession) -> String? {
        let base = ((session.id as NSString).lastPathComponent as NSString).deletingPathExtension
        let key = base.hasPrefix("opencode-") ? String(base.dropFirst("opencode-".count)) : base
        // Codex rollout files are `rollout-<date>-<uuid>.jsonl`; keep just the trailing UUID.
        if let r = key.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) {
            return String(key[r])
        }
        return key.count >= 8 ? key : nil
    }

    private static func agentPids(for provider: ProviderID, sessionKey: String?) -> [(pid: pid_t, headless: Bool, exact: Bool, namesOtherSession: Bool)] {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,args="]) else { return [] }
        var pids: [(pid: pid_t, headless: Bool, exact: Bool, namesOtherSession: Bool)] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }
            let args = parts[1].lowercased()
            let flags = args.split(separator: " ")
            // Skip ourselves by executable, not by substring: agents launched with `--add-dir .../UsageBar` are real sessions.
            if pid == ProcessInfo.processInfo.processIdentifier || (flags.first?.contains("usagebar") ?? false) { continue }
            guard LiveSessionScanner.commandLine(args, matches: provider) else { continue }
            // `claude -p` / `codex exec` run non-interactively; there is no TUI to show for them.
            let headless = flags.contains("-p") || flags.contains("--print") || (provider == .codex && flags.contains("exec"))
            let exact = sessionKey.map { args.contains($0.lowercased()) } ?? false
            // `--session-id X`, `--resume X`, `-r X`, `codex resume X`, `--session X`: the process tells us which session it is.
            var namesOther = false
            for (i, f) in flags.enumerated() where ["--session-id", "--resume", "-r", "resume", "--session", "-s"].contains(f) {
                if i + 1 < flags.count, !flags[i + 1].hasPrefix("-"), String(flags[i + 1]) != (sessionKey?.lowercased() ?? "") { namesOther = true }
            }
            pids.append((pid, headless, exact, namesOther))
        }
        return pids
    }

    /// pid → current working directory, via lsof (exit status is nonzero when any pid has no cwd; ignore it).
    private static func cwds(of pids: [pid_t]) -> [pid_t: String] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = Shell.run("/usr/sbin/lsof", ["-a", "-w", "-d", "cwd", "-p", list, "-Fpn"], requireSuccess: false) else { return [:] }
        var map: [pid_t: String] = [:]
        var current: pid_t?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let c = current { map[c] = normalize(String(line.dropFirst())) }
        }
        return map
    }

    private static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func resolve(_ path: String) -> String {
        normalize(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    // MARK: Bring the host to the front

    @discardableResult
    private static func activate(_ host: Host) -> Bool {
        var app: NSRunningApplication?
        if let bundlePath = host.bundlePath {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundlePath }
        }
        if app == nil, let pid = host.appPid { app = NSRunningApplication(processIdentifier: pid) }
        guard let app, app.activationPolicy != .prohibited else { return false }
        // Cooperative activation: we are the active app while the popover is open, so hand focus over directly.
        let ok = app.activate(from: .current, options: [.activateAllWindows])
        if !ok { NSApplication.shared.yieldActivation(to: app); return app.activate(options: [.activateAllWindows]) }
        return true
    }

    /// Terminal.app and iTerm2 expose the tty of each tab; jump straight to the agent's tab.
    private static func selectTab(_ host: Host) {
        guard let tty = host.tty, let bundlePath = host.bundlePath else { return }
        let dev = "/dev/\(tty)"
        let script: String
        switch (bundlePath as NSString).lastPathComponent {
        case "Terminal.app":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(dev)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "iTerm.app", "iTerm2.app":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(dev)" then
                                tell w to select
                                tell t to select
                                tell s to select
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10) }
    }

    // MARK: Open a new terminal in the folder, optionally running the resume command

    /// `cd '<dir>' && <command>` with the directory single-quoted for the shell.
    private static func shellLine(cwd: String, command: String?) -> String {
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : Files.home
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return command.map { "cd \(quoted) && \($0)" } ?? "cd \(quoted)"
    }

    private static func openTerminal(at cwd: String, running command: String?) {
        let ws = NSWorkspace.shared
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : Files.home
        let line = shellLine(cwd: cwd, command: command)  // Terminal/iTerm run this in a fresh shell
        DispatchQueue.global(qos: .userInitiated).async {
            if ws.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
                // Ghostty ≥ 1.3 is scriptable: open a tab in the front window (or a window if there is none) with the
                // session's folder as its working directory and the resume command as initial input. No second instance,
                // and no "allow this command?" prompt, which only `-e` launches trigger.
                let input = command.map { "set initial input of cfg to \"\(appleScriptEscaped($0))\" & return" } ?? ""
                _ = Shell.run("/usr/bin/osascript", ["-e", """
                    tell application "Ghostty"
                        set cfg to new surface configuration
                        set initial working directory of cfg to "\(appleScriptEscaped(dir))"
                        \(input)
                        if (count of windows) is 0 then
                            set w to new window with configuration cfg
                            set t to selected tab of w
                        else
                            set w to front window
                            if w is missing value then set w to window 1
                            set t to new tab in w with configuration cfg
                        end if
                        focus (focused terminal of t)
                        activate
                    end tell
                    """], timeout: 20)
            } else if ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
                if command == nil { _ = Shell.run("/usr/bin/open", ["-b", "com.googlecode.iterm2", dir]); return }
                _ = Shell.run("/usr/bin/osascript", ["-e", """
                    tell application "iTerm2"
                        activate
                        set w to (create window with default profile)
                        tell current session of w to write text "\(appleScriptEscaped(line))"
                    end tell
                    """], timeout: 10)
            } else {
                if command == nil { _ = Shell.run("/usr/bin/open", ["-b", "com.apple.Terminal", dir]); return }
                _ = Shell.run("/usr/bin/osascript", ["-e", """
                    tell application "Terminal"
                        activate
                        do script "\(appleScriptEscaped(line))"
                    end tell
                    """], timeout: 10)
            }
        }
    }

    private static func appleScriptEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
