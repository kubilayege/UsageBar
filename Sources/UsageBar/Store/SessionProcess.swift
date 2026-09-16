import Foundation

struct SessionProcess {
    var pid: Int32
    var provider: ProviderID
    var sessionID: String?
    var cwd: String?
    var logs: Set<String> = []
    var headless = false

    func matches(sessionID: String, path: String) -> Bool {
        self.sessionID == sessionID || logs.contains(path)
    }

    static func sessionKey(_ path: String) -> String {
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.range(of: #"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"#, options: .regularExpression).map { String(base[$0]) } ?? base
    }

    static func provider(command: String) -> ProviderID? {
        let words = command.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        let executable = (first as NSString).lastPathComponent
        for provider in [ProviderID.claude, .codex, .opencode] {
            if executable == provider.rawValue { return provider }
        }
        if first.contains("/claude/versions/") { return .claude }
        if command.lowercased().hasPrefix("/applications/codex.app/contents/macos/codex") { return .codex }
        if ["node", "bun"].contains(executable), words.count > 1 {
            let script = words[1]
            if script.contains("@anthropic-ai/claude-code/") { return .claude }
            if script.contains("@openai/codex/") { return .codex }
            if script.contains("opencode") { return .opencode }
        }
        return nil
    }

    static func namedSession(_ words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            // ps can include arbitrary prompt text, including standalone '=' and '=='.
            // Preserve empty fields, and never subscript before confirming a flag exists.
            let pair = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if let flag = pair.first, ["--session-id", "--resume", "-r", "resume", "--session", "-s"].contains(flag) {
                let value = pair.count == 2 ? pair[1] : (index + 1 < words.count ? words[index + 1] : "")
                if UUID(uuidString: value) != nil { return value }
            }
        }
        return nil
    }

    static func scan() -> [SessionProcess] {
        guard let ps = Shell.run("/bin/ps", ["-axo", "pid=,args="]) else { return [] }
        var processes: [Int32: SessionProcess] = [:]
        for line in ps.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let pid = Int32(fields[0]), let provider = provider(command: String(fields[1])) else { continue }
            let words = fields[1].split(whereSeparator: \.isWhitespace).map(String.init)
            processes[pid] = SessionProcess(pid: pid, provider: provider, sessionID: namedSession(words),
                headless: words.contains("-p") || words.contains("--print") || words.contains("exec"))
        }
        guard !processes.isEmpty else { return [] }
        let pids = processes.keys.map(String.init).joined(separator: ",")
        if let output = Shell.run("/usr/sbin/lsof", ["-a", "-w", "-p", pids, "-Fpfn"], requireSuccess: false) {
            var pid: Int32?, descriptor = ""
            for line in output.split(separator: "\n") {
                if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
                else if line.hasPrefix("f") { descriptor = String(line.dropFirst()) }
                else if line.hasPrefix("n"), let pid {
                    let path = String(line.dropFirst())
                    if descriptor == "cwd" { processes[pid]?.cwd = URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
                    else if path.hasSuffix(".jsonl") { processes[pid]?.logs.insert(path) }
                }
            }
        }
        // Claude's session registry associates idle sessions with a PID even when the log is closed.
        let registry = Files.claudeRoot + "/sessions"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: registry)) ?? [] where file.hasSuffix(".json") {
            guard let record = Files.readJSON(registry + "/" + file), let pid = record.int("pid"),
                  let processID = Int32(exactly: pid), processes[processID]?.provider == .claude,
                  let id = record.string("sessionId"), UUID(uuidString: id) != nil else { continue }
            processes[processID]?.sessionID = id
        }
        return Array(processes.values)
    }
}
