import Foundation
import Sparkle

@MainActor
struct UpdateCheckerTests {
    func testPreferenceMigrationPreservesOptOutAndSparkleChoice() {
        let suite = "usagebar-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UpdateChecker.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool, nil)
        defaults.set(false, forKey: "checkForUpdates")
        UpdateChecker.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.bool(forKey: "SUEnableAutomaticChecks"), false)
        // Sparkle preferences win after the one-time migration, including changes from its own UI.
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        UpdateChecker.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.bool(forKey: "SUEnableAutomaticChecks"), true)
        defaults.set(true, forKey: "checkForUpdates")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        UpdateChecker.migratePreferences(in: defaults)
        XCTAssertEqual(defaults.bool(forKey: "SUEnableAutomaticChecks"), false)
    }

    func testPreviewNeverStartsUpdater() {
        let previous = RenderFlags.isRendering
        RenderFlags.isRendering = true
        defer { RenderFlags.isRendering = previous }
        let checker = UpdateChecker()
        checker.start()
        checker.check()
        XCTAssertEqual(checker.isEnabled, false)
        XCTAssertEqual(checker.canCheckForUpdates, false)
        XCTAssertEqual(checker.phase, .idle)
    }

    func testSparkleDelegateCallbacksAndErrors() {
        let checker = UpdateChecker()
        // Optional ObjC protocol methods can compile under the wrong Swift spelling without
        // ever being called. Check the selectors Sparkle actually sends.
        for selector in ["updater:mayPerformUpdateCheck:error:", "updater:didFindValidUpdate:",
                         "updaterDidNotFindUpdate:error:", "updater:didAbortWithError:",
                         "updater:userDidMakeChoice:forUpdate:state:"] {
            XCTAssertTrue(checker.responds(to: NSSelectorFromString(selector)))
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        checker.updaterDidNotFindUpdate(updater, error: noUpdate)
        checker.updater(updater, didAbortWithError: noUpdate)
        XCTAssertEqual(checker.phase, .noUpdate)
        XCTAssertEqual(checker.isUpdateAvailable, false)

        // A failed check must not claim there are no releases or that the app is up to date.
        let failure = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue),
                              userInfo: [NSLocalizedDescriptionKey: "Feed unavailable"])
        checker.updater(updater, didAbortWithError: failure)
        XCTAssertEqual(checker.phase, .failed("Feed unavailable"))
        try? checker.updater(updater, mayPerform: .updates)
        XCTAssertEqual(checker.phase, .checking)
    }
}
