import AppKit
import Foundation
import LocalAuthentication

/// Keeps authentication regressions independent of this Mac's hardware and never opens a prompt.
private final class SleepAuthenticationContext: LAContext {
    var isAvailable = true
    var evaluationError: LAError.Code?
    var evaluatedPolicies: [LAPolicy] = []

    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        if !isAvailable { error?.pointee = LAError(.notInteractive) as NSError }
        return isAvailable
    }

    override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String,
                                 reply: @escaping (Bool, Error?) -> Void) {
        evaluatedPolicies.append(policy)
        if let evaluationError { reply(false, LAError(evaluationError)) }
        else { reply(true, nil) }
    }
}

struct SystemControlTests {
    @MainActor func testSleepTracksSystemAndFailedChanges() async {
        XCTAssertEqual(SleepControl.parse("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1"), true)
        XCTAssertEqual(SleepControl.parse(" SleepDisabled 0\n sleep 1 (sleep prevented by coreaudiod)"), false)
        XCTAssertEqual(SleepControl.parse("sleep 1\ndisplaysleep 0"), nil)
        var system = true
        var writes: [Bool] = []
        let control = SleepControl(read: { system }, write: { value in writes.append(value); system = value; return nil }, accessInstalled: { false })
        await control.refresh()
        XCTAssertEqual(control.isSleepDisabled, true)
        await control.toggle()
        XCTAssertEqual(writes, [false])
        XCTAssertEqual(control.isSleepDisabled, false)
        system = true
        await control.refresh()
        XCTAssertEqual(control.isSleepDisabled, true)
        let rejected = SleepControl(read: { true }, write: { _ in "cancelled" }, accessInstalled: { false })
        await rejected.toggle()
        XCTAssertEqual(rejected.isSleepDisabled, true)
        XCTAssertEqual(rejected.errorMessage, "cancelled")
        let unconfirmed = SleepControl(read: { true }, write: { _ in nil }, accessInstalled: { false })
        await unconfirmed.toggle()
        XCTAssertTrue(unconfirmed.errorMessage != nil)
        XCTAssertEqual(unconfirmed.isChanging, false)
    }

    @MainActor func testPasswordlessRuleAndTouchIDGate() async {
        XCTAssertEqual(SleepAccess.rule(uid: 502), "#502 ALL = (root) NOPASSWD: /usr/bin/pmset -b disablesleep 0, /usr/bin/pmset -b disablesleep 1")
        XCTAssertEqual(SleepAccess.command(true), ["/usr/bin/pmset", "-b", "disablesleep", "1"])
        XCTAssertEqual(SleepAccess.rulePath(uid: 502), "/private/etc/sudoers.d/usagebar-502")
        XCTAssertTrue(SleepAccess.rulePath(uid: 501) != SleepAccess.rulePath(uid: 502))
        let script = SleepAccess.installScript(uid: 502)
        XCTAssertTrue(script.contains("'\(SleepAccess.rule(uid: 502))'"))
        XCTAssertTrue(script.contains("dest=\(SleepAccess.rulePath(uid: 502))\n"))
        XCTAssertTrue(script.contains("printf '%s\\n'"))
        XCTAssertEqual(script.contains("/tmp"), false)
        // Parse only: never install/remove a rule or change the host's sleep state in tests.
        XCTAssertEqual(Shell.runResult("/bin/sh", ["-n", "-c", script])?.status, 0)
        XCTAssertEqual(Shell.runResult("/bin/sh", ["-n", "-c", SleepAccess.removeScript(uid: 502)])?.status, 0)
        XCTAssertEqual(SleepAccess.failureReason("0:95: execution error: UsageBar: The generated rule did not pass visudo. (1)"), "The generated rule did not pass visudo.")
        XCTAssertEqual(SleepAccess.failureReason("0:95: execution error: visudo: syntax error (1)"), nil)

        var installed = true, confirmations: [Bool] = [], writes: [Bool] = []
        var system = false, requireTouchID = true, confirmResult: String? = "cancelled"
        let control = SleepControl(read: { system }, write: { value in writes.append(value); system = value; return nil },
                                   confirm: { value in confirmations.append(value); return confirmResult },
                                   requiresConfirmation: { requireTouchID }, accessInstalled: { installed },
                                   changeAccess: { enabled in installed = enabled; return nil })
        await control.toggle()
        XCTAssertEqual(confirmations, [true])
        XCTAssertEqual(writes, [])
        XCTAssertEqual(control.errorMessage, "cancelled")
        XCTAssertEqual(control.isSleepDisabled, false)
        confirmResult = nil
        await control.toggle()
        XCTAssertEqual(writes, [true])
        XCTAssertEqual(control.isSleepDisabled, true)
        XCTAssertEqual(control.errorMessage, nil)
        requireTouchID = false
        await control.toggle()
        XCTAssertEqual(confirmations, [true, true])
        XCTAssertEqual(writes, [true, false])

        await control.setPasswordless(false)
        XCTAssertEqual(control.isPasswordless, false)
        requireTouchID = true
        await control.toggle()
        // Without the rule macOS asks for the password anyway, so Touch ID is skipped.
        XCTAssertEqual(confirmations, [true, true])
        XCTAssertEqual(writes, [true, false, true])
        await control.setPasswordless(true)
        XCTAssertEqual(control.isPasswordless, true)
        XCTAssertEqual(control.errorMessage, nil)

        let refused = SleepControl(read: { false }, write: { _ in nil }, confirm: { _ in nil }, requiresConfirmation: { false },
                                   accessInstalled: { false }, changeAccess: { _ in nil })
        await refused.setPasswordless(true)
        XCTAssertEqual(refused.isPasswordless, false)
        XCTAssertTrue(refused.errorMessage != nil)
        XCTAssertEqual(refused.isChanging, false)
    }

    @MainActor func testSleepAuthenticationFailsClosed() async {
        let unavailable = SleepAuthenticationContext()
        unavailable.isAvailable = false
        let unavailableError = await SleepControl.confirmWithTouchID(true, context: unavailable)
        XCTAssertTrue(unavailableError != nil)
        XCTAssertEqual(unavailable.evaluatedPolicies, [])

        for code in [LAError.Code.userCancel, .appCancel, .systemCancel] {
            let cancelled = SleepAuthenticationContext()
            cancelled.evaluationError = code
            let message = await SleepControl.confirmWithTouchID(true, context: cancelled)
            XCTAssertTrue(message?.localizedCaseInsensitiveContains("cancelled") == true)
            XCTAssertEqual(cancelled.evaluatedPolicies, [.deviceOwnerAuthentication])
        }

        let failed = SleepAuthenticationContext()
        failed.evaluationError = .authenticationFailed
        let failure = await SleepControl.confirmWithTouchID(false, context: failed)
        XCTAssertTrue(failure != nil)

        let approved = SleepAuthenticationContext()
        let success = await SleepControl.confirmWithTouchID(false, context: approved)
        XCTAssertEqual(success, nil)
        XCTAssertEqual(approved.evaluatedPolicies, [.deviceOwnerAuthentication])
    }

    func testSleepCommandsUsePasswordlessAccessAndAdministratorFallback() {
        let success = Shell.Result(output: "", error: "", status: 0)
        for disabled in [false, true] {
            let command = ["/usr/bin/pmset", "-b", "disablesleep", disabled ? "1" : "0"]
            var sudoCalls: [[String]] = []
            var administratorCalls: [String] = []
            let passwordless = SleepControl.applySystemChange(disabled, passwordless: true,
                runWithoutPassword: { arguments in sudoCalls.append(arguments); return success },
                runAsAdministrator: { script, _ in administratorCalls.append(script); return success })
            XCTAssertEqual(passwordless, nil)
            XCTAssertEqual(sudoCalls, [["-n"] + command])
            XCTAssertEqual(administratorCalls, [])

            sudoCalls = []
            let regular = SleepControl.applySystemChange(disabled, passwordless: false,
                runWithoutPassword: { arguments in sudoCalls.append(arguments); return success },
                runAsAdministrator: { script, prompt in
                    administratorCalls.append(script)
                    XCTAssertTrue(!prompt.isEmpty)
                    return success
                })
            XCTAssertEqual(regular, nil)
            XCTAssertEqual(sudoCalls, [])
            XCTAssertEqual(administratorCalls, [command.joined(separator: " ")])
        }

        // A timeout or localized rejection must still offer macOS authorization.
        let rejectedAttempts: [Shell.Result?] = [nil, Shell.Result(output: "", error: "Parola gerekli", status: 1)]
        for rejected in rejectedAttempts {
            var administratorCalls = 0
            let warning = SleepControl.applySystemChange(true, passwordless: true,
                runWithoutPassword: { _ in rejected },
                runAsAdministrator: { script, _ in
                    administratorCalls += 1
                    XCTAssertEqual(script, "/usr/bin/pmset -b disablesleep 1")
                    return success
                })
            XCTAssertEqual(administratorCalls, 1)
            XCTAssertTrue(warning?.contains("passwordless") == true || warning?.contains("Passwordless") == true)
        }

        for passwordless in [false, true] {
            let cancelled = SleepControl.applySystemChange(false, passwordless: passwordless,
                runWithoutPassword: { _ in nil },
                runAsAdministrator: { _, _ in Shell.Result(output: "", error: "execution error: User canceled. (-128)", status: 1) })
            XCTAssertTrue(cancelled?.localizedCaseInsensitiveContains("cancelled") == true)
            for rejected in rejectedAttempts {
                let failure = SleepControl.applySystemChange(false, passwordless: passwordless,
                    runWithoutPassword: { _ in nil }, runAsAdministrator: { _, _ in rejected })
                XCTAssertTrue(failure?.contains("Could not change") == true)
            }
        }
    }

    @MainActor func testCancelledSleepConfirmationReadsCurrentSystemState() async {
        var system = false
        var reads = 0
        var writes: [Bool] = []
        let control = SleepControl(read: { reads += 1; return system },
                                   write: { value in writes.append(value); return nil },
                                   confirm: { _ in
                                       // A different process changes pmset while the prompt is open.
                                       system = true
                                       return "Change cancelled. The current system setting is shown."
                                   }, requiresConfirmation: { true }, accessInstalled: { true })
        await control.toggle()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(control.isSleepDisabled, true)
        XCTAssertTrue(control.errorMessage?.contains("cancelled") == true)
        XCTAssertEqual(control.isChanging, false)
    }

    @MainActor func testPasswordlessAccessCancellationPreservesState() async {
        for installed in [false, true] {
            var changes: [Bool] = []
            let control = SleepControl(read: { false }, write: { _ in nil },
                                       accessInstalled: { installed }, changeAccess: { enabled in
                                           changes.append(enabled)
                                           return "Cancelled. Nothing was changed."
                                       })
            await control.setPasswordless(!installed)
            XCTAssertEqual(changes, [!installed])
            XCTAssertEqual(control.isPasswordless, installed)
            XCTAssertEqual(control.errorMessage, "Cancelled. Nothing was changed.")
            XCTAssertEqual(control.isChanging, false)
        }
    }

    @MainActor func testOldRefreshCannotClearPasswordlessAccessError() async {
        var pendingRead: CheckedContinuation<Bool?, Never>?
        let control = SleepControl(read: {
            await withCheckedContinuation { pendingRead = $0 }
        }, write: { _ in nil }, accessInstalled: { false }, changeAccess: { _ in "Setup cancelled." })
        let refresh = Task { await control.refresh() }
        while pendingRead == nil { await Task.yield() }

        await control.setPasswordless(true)
        XCTAssertEqual(control.errorMessage, "Setup cancelled.")
        pendingRead?.resume(returning: false)
        await refresh.value
        XCTAssertEqual(control.errorMessage, "Setup cancelled.")
        XCTAssertEqual(control.isSleepDisabled, nil)
        XCTAssertEqual(control.isPasswordless, false)
        XCTAssertEqual(control.isChanging, false)
    }

    @MainActor func testSleepConfirmationDefaultsOnAndPersistsChoice() {
        let suiteName = "usagebar-sleep-regression-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.confirmSleepWithTouchID, true)
        settings.confirmSleepWithTouchID = false
        XCTAssertEqual(AppSettings(defaults: defaults).confirmSleepWithTouchID, false)
        settings.confirmSleepWithTouchID = true
        XCTAssertEqual(AppSettings(defaults: defaults).confirmSleepWithTouchID, true)
    }

    @MainActor func testWhiteIconAndBankedResets() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let icon = MenuBarIcon.whiteLogo()
                XCTAssertEqual(icon.isTemplate, false)
                let bitmap = NSBitmapImageRep(data: icon.tiffRepresentation!)!
                var visible = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1 else { continue }
                        visible += 1
                        XCTAssertTrue(color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98)
                    }
                }
                XCTAssertTrue(visible > 10)
            }
        }
        let provider = CodexProvider()
        var json: JSON = ["rate_limit": ["primary_window": ["used_percent": 11, "limit_window_seconds": 604800]],
                          "rate_limit_reset_credits": ["available_count": 1, "applicable_available_count": 0]]
        let snapshot = try provider.parse(json)
        XCTAssertEqual(snapshot.bankedResets, BankedResets(available: 1, applicable: 0))
        let roundtrip = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(roundtrip.bankedResets, snapshot.bankedResets)
        json["rate_limit_reset_credits"] = nil
        XCTAssertEqual(try provider.parse(json).bankedResets, nil)
    }
}
