import Foundation
import Combine
import LocalAuthentication

/// Controls the actual pmset setting. No saved preference or idle-sleep assertion.
@MainActor
final class SleepControl: ObservableObject {
    static let shared = SleepControl()
    @Published private(set) var isSleepDisabled: Bool?
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    /// Whether UsageBar's sudoers rule is installed, so changes skip the administrator prompt.
    @Published private(set) var isPasswordless: Bool
    private var isReading = false
    private var revision = 0
    private let read: () async -> Bool?
    private let write: (Bool) async -> String?
    private let confirm: (Bool) async -> String?
    private let requiresConfirmation: @MainActor () -> Bool
    private let accessInstalled: () -> Bool
    private let changeAccess: (Bool) async -> String?

    init(read: @escaping () async -> Bool? = SleepControl.readSystem,
         write: @escaping (Bool) async -> String? = SleepControl.writeSystem,
         confirm: @escaping (Bool) async -> String? = { await SleepControl.confirmWithTouchID($0) },
         requiresConfirmation: @escaping @MainActor () -> Bool = { AppSettings.shared.confirmSleepWithTouchID },
         accessInstalled: @escaping () -> Bool = { SleepAccess.isInstalled },
         changeAccess: @escaping (Bool) async -> String? = SleepControl.writeAccess) {
        self.read = read
        self.write = write
        self.confirm = confirm
        self.requiresConfirmation = requiresConfirmation
        self.accessInstalled = accessInstalled
        self.changeAccess = changeAccess
        isPasswordless = accessInstalled()
    }

    var stateLabel: String {
        if isChanging { return "Applying…" }
        return isSleepDisabled.map { $0 ? "ON" : "OFF" } ?? "Unknown"
    }

    func refresh() async {
        guard !isReading, !isChanging else { return }
        isPasswordless = accessInstalled()
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
        // Touch ID only guards UsageBar's own button; without the rule, macOS asks for the password anyway.
        isPasswordless = accessInstalled()
        if isPasswordless, requiresConfirmation(), let error = await confirm(desired) {
            isSleepDisabled = await read()
            errorMessage = error
            return
        }
        let error = await write(desired)
        isSleepDisabled = await read()
        if let error { errorMessage = error }
        else if isSleepDisabled != desired { errorMessage = "macOS did not confirm the new sleep setting. Try again." }
    }

    /// Installs or removes the sudoers rule through one administrator prompt.
    func setPasswordless(_ enabled: Bool) async {
        guard !isChanging else { return }
        isChanging = true
        revision += 1
        errorMessage = nil
        defer { isChanging = false }
        if let error = await changeAccess(enabled) { errorMessage = error }
        isPasswordless = accessInstalled()
        if errorMessage == nil, isPasswordless != enabled {
            errorMessage = enabled ? "The passwordless rule was not installed. Try again." : "The passwordless rule is still installed. Try again."
        }
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
            applySystemChange(disabled, passwordless: SleepAccess.isInstalled,
                              runWithoutPassword: { Shell.runResult("/usr/bin/sudo", $0, timeout: 10) },
                              runAsAdministrator: { SleepAccess.runAsAdministrator($0, prompt: $1) })
        }.value
    }

    nonisolated static func applySystemChange(
        _ disabled: Bool, passwordless: Bool,
        runWithoutPassword: ([String]) -> Shell.Result?,
        runAsAdministrator: (String, String) -> Shell.Result?
    ) -> String? {
        let command = SleepAccess.command(disabled)
        if passwordless, runWithoutPassword(["-n"] + command)?.status == 0 { return nil }
        // Any sudo failure (including localized errors or timeouts) can fall back to macOS approval.
        // Setting the desired value twice is safe if the first attempt finished after its timeout.
        let result = runAsAdministrator(command.joined(separator: " "),
                                        disabled ? "UsageBar wants to disable sleep." : "UsageBar wants to allow sleep again.")
        if result?.status == 0 {
            return passwordless ? "Passwordless access failed, so macOS administrator approval was used. Turn passwordless mode off and on again in Settings." : nil
        }
        if result?.error.contains("-128") == true { return "Change cancelled. The current system setting is shown." }
        return "Could not change the sleep setting. Try again and approve the macOS administrator prompt."
    }

    nonisolated static func writeAccess(_ enabled: Bool) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let uid = getuid()
            guard uid != 0 else { return "UsageBar is running as root; passwordless mode is only for a regular account." }
            let result = enabled
                ? SleepAccess.runAsAdministrator(SleepAccess.installScript(uid: uid), prompt: "UsageBar wants to let your account turn sleep on or off without a password.")
                : SleepAccess.runAsAdministrator(SleepAccess.removeScript(uid: uid), prompt: "UsageBar wants to remove its passwordless sleep rule.")
            guard result?.status != 0 else { return nil }
            if result?.error.contains("-128") == true { return "Cancelled. Nothing was changed." }
            return result.flatMap { SleepAccess.failureReason($0.error) }
                ?? (enabled ? "Could not install the passwordless rule." : "Could not remove the passwordless rule.")
        }.value
    }

    /// A click guard in front of the rule, not an OS privilege boundary: other processes running as
    /// this user can still use the rule directly. Touch ID with the login password as fallback.
    nonisolated static func confirmWithTouchID(_ disabled: Bool, context: LAContext = LAContext()) async -> String? {
        var unavailable: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            return "Authentication is unavailable. No change was made. Try again when Touch ID or your login password is available."
        }
        do {
            let confirmed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: disabled ? "disable sleep" : "allow sleep again")
            return confirmed ? nil : "Authentication did not confirm the change. No change was made."
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return "Change cancelled. The current system setting is shown."
        } catch {
            return "Authentication did not confirm the change. Try again."
        }
    }
}
