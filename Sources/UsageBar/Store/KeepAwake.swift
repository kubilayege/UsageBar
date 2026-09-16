import Foundation
import Combine

/// Controls the actual pmset setting. No saved preference or idle-sleep assertion.
@MainActor
final class SleepControl: ObservableObject {
    static let shared = SleepControl()
    @Published private(set) var isSleepDisabled: Bool?
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    private var isReading = false
    private var revision = 0
    private let read: () async -> Bool?
    private let write: (Bool) async -> String?

    init(read: @escaping () async -> Bool? = SleepControl.readSystem,
         write: @escaping (Bool) async -> String? = SleepControl.writeSystem) {
        self.read = read
        self.write = write
    }

    var stateLabel: String {
        if isChanging { return "Applying…" }
        return isSleepDisabled.map { $0 ? "ON" : "OFF" } ?? "Unknown"
    }

    func refresh() async {
        guard !isReading, !isChanging else { return }
        isReading = true
        let currentRevision = revision
        let value = await read()
        isReading = false
        guard currentRevision == revision else { return }
        isSleepDisabled = value
        if value == nil { errorMessage = "Could not read the sleep setting. Try refreshing." }
        else { errorMessage = nil }
    }

    func toggle() async {
        guard !isChanging else { return }
        // Read immediately before a change in case pmset was changed in Terminal.
        isChanging = true
        revision += 1
        errorMessage = nil
        defer { isChanging = false }
        guard let current = await read() else {
            isSleepDisabled = nil
            errorMessage = "Could not read the sleep setting. No change was made."
            return
        }
        isSleepDisabled = current
        let desired = !current
        let error = await write(desired)
        isSleepDisabled = await read()
        if let error { errorMessage = error }
        else if isSleepDisabled != desired { errorMessage = "macOS did not confirm the new sleep setting. Try again." }
    }

    nonisolated static func parse(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, ["sleepdisabled", "disablesleep"].contains(fields[0].lowercased()) else { continue }
            if fields[1] == "1" { return true }
            if fields[1] == "0" { return false }
        }
        return nil
    }

    nonisolated static func readSystem() async -> Bool? {
        await Task.detached(priority: .utility) {
            Shell.run("/usr/bin/pmset", ["-g"]).flatMap(Self.parse)
        }.value
    }

    nonisolated static func writeSystem(_ disabled: Bool) async -> String? {
        await Task.detached(priority: .userInitiated) {
            // macOS owns authentication; no password is collected or stored by UsageBar.
            let script = "do shell script \"/usr/bin/pmset -b disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
            let result = Shell.runResult("/usr/bin/osascript", ["-e", script], timeout: 120)
            guard result?.status != 0 else { return nil }
            if result?.error.contains("-128") == true { return "Change cancelled. The current system setting is shown." }
            return "Could not change the sleep setting. Try again and approve the macOS administrator prompt."
        }.value
    }
}
