import Foundation

var failures = 0
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { failures += 1; print("FAIL \(file):\(line): \(actual) != \(expected)") }
}
func XCTAssertTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, true, file: file, line: line)
}

@main
struct BehaviorRegression {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--usagebar-test-agent") {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return
        }
        let process = SessionProcessTests()
        process.testUnrelatedEqualsArgumentsNeverCrash()
        process.testSessionFlagsSurviveUnrelatedArguments()
        try process.testLiveProcessScanWithEqualsArgument()
        let scanner = SessionScannerTests()
        try scanner.testClaudeReadsJSONAndKeepsRealModelAfterSyntheticMessage()
        try scanner.testClaudeDoesNotTreatTouchedHistoricalLogAsRecentActivity()
        try scanner.testOnlyMatchingClaudeSessionIsRunningAndIdleSessionIsRetained()
        let defaults = UserDefaults(suiteName: "usagebar-regression-" + UUID().uuidString)!
        XCTAssertEqual(AppSettings(defaults: defaults).menuBarMode, .icon)
        let system = SystemControlTests()
        await system.testSleepTracksSystemAndFailedChanges()
        await system.testPasswordlessRuleAndTouchIDGate()
        await system.testSleepAuthenticationFailsClosed()
        system.testSleepCommandsUsePasswordlessAccessAndAdministratorFallback()
        await system.testCancelledSleepConfirmationReadsCurrentSystemState()
        await system.testPasswordlessAccessCancellationPreservesState()
        await system.testOldRefreshCannotClearPasswordlessAccessError()
        system.testSleepConfirmationDefaultsOnAndPersistsChoice()
        try system.testWhiteIconAndBankedResets()
        let updates = UpdateCheckerTests()
        updates.testPreferenceMigrationPreservesOptOutAndSparkleChoice()
        updates.testPreviewNeverStartsUpdater()
        updates.testSparkleDelegateCallbacksAndErrors()
        let analysis = AnalysisTests()
        try analysis.testRepeatedCodexCountersAndEffortChanges()
        try analysis.testClaudeStreamingKeepsFinalUsage()
        analysis.testUnknownCostsDoNotWinAndDateRangeIsExact()
        analysis.testCostPlotWeightsTurnsAndClipsRange()
        analysis.testCostPlotMissingRatesAndGapsAreNotZero()
        analysis.testCostPlotHourlyBucketsAndSeparateEfforts()
        analysis.testCostPlotUsesLocalCalendarAcrossDST()
        analysis.testListPricesMatchLoggedModelNamesAndOverridesWin()
        XCTAssertEqual(SessionProcess.provider(command: "python script.py --prompt claude-code"), nil)
        XCTAssertEqual(SessionProcess.provider(command: "claude --add-dir /tmp/UsageBar"), .claude)
        XCTAssertEqual(SessionProcess.provider(command: "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"), .claude)
        print("Behavior regressions: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
