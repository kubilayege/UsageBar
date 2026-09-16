import Foundation

struct SessionProcessTests {
    func testUnrelatedEqualsArgumentsNeverCrash() {
        XCTAssertEqual(SessionProcess.namedSession(["claude", "="]), nil)
        XCTAssertEqual(SessionProcess.namedSession(["codex", "==", "===", "", "--resume=", "--resume"]), nil)
        XCTAssertEqual(SessionProcess.namedSession(["claude", "--resume", "=", "--session-id=="]), nil)
    }

    func testSessionFlagsSurviveUnrelatedArguments() {
        let id = "a8e24a8d-b7fc-455f-b488-022f2a6a7d4a"
        for flag in ["--session-id", "--resume", "-r", "resume", "--session", "-s"] {
            XCTAssertEqual(SessionProcess.namedSession(["claude", "=", "", flag, id]), id)
            XCTAssertEqual(SessionProcess.namedSession(["claude", "==", flag + "=" + id]), id)
        }
        XCTAssertEqual(SessionProcess.namedSession(["claude", "unrelated=" + id]), nil)
        XCTAssertEqual(SessionProcess.namedSession(["claude", "--resume=", id]), nil)
        XCTAssertEqual(SessionProcess.namedSession(["claude", "=--resume", id]), nil)
    }

    func testLiveProcessScanWithEqualsArgument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[0]))
        let fixture = Process()
        fixture.executableURL = executable
        let id = "a8e24a8d-b7fc-455f-b488-022f2a6a7d4a"
        fixture.arguments = ["--usagebar-test-agent", "=", "==", "--session-id", id]
        fixture.standardOutput = FileHandle.nullDevice
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer { if fixture.isRunning { fixture.terminate() }; fixture.waitUntilExit() }
        for _ in 0..<4 {
            let found = SessionProcess.scan().first { $0.pid == fixture.processIdentifier }
            XCTAssertEqual(found?.provider, .claude)
            XCTAssertEqual(found?.sessionID, id)
        }
    }
}
