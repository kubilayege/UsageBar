import Foundation

@MainActor
struct UpdateCheckerTests {
    private let page = URL(string: "https://github.com/kubilayege/UsageBar/releases/tag/v1.2.1")!
    private let dmg = "https://github.com/kubilayege/UsageBar/releases/download/v1.2.1/UsageBar-1.2.1-arm64.dmg"

    private func response(_ url: URL, _ status: Int, _ body: String = "", headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func testRateLimitedAPIUsesPublicReleaseAndRespectsRetryTime() async {
        for status in [403, 429] {
            let suite = "usagebar-update-tests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var apiRequests = 0
            var publicRequests = 0
            let request: UpdateChecker.Request = { url, headers in
                if url.host == "api.github.com" {
                    apiRequests += 1
                    return response(url, status, #"{"message":"API rate limit exceeded"}"#,
                                    headers: ["X-RateLimit-Remaining": "0",
                                              "X-RateLimit-Reset": String(Int(Date().timeIntervalSince1970 + 3600))])
                }
                publicRequests += 1
                XCTAssertEqual(headers["Accept"], "text/html")
                if url.lastPathComponent == "latest" { return response(page, 200) }
                XCTAssertEqual(url.path, "/kubilayege/UsageBar/releases/expanded_assets/v1.2.1")
                return response(url, 200, """
                <a href="https://example.com/other.dmg">Unrelated download</a>
                <a href="/kubilayege/UsageBar/releases/download/v1.2.1/other.dmg.sha256">Other checksum</a>
                <a href="\(dmg)">DMG</a>
                <a href="\(dmg).sha256">SHA256</a>
                """)
            }
            let checker = UpdateChecker(defaults: defaults, request: request)
            await checker.check()
            XCTAssertEqual(checker.latest?.version, "1.2.1")
            XCTAssertEqual(checker.latest?.dmg.absoluteString, dmg)
            XCTAssertEqual(checker.latest?.checksum?.absoluteString, dmg + ".sha256")
            XCTAssertEqual(checker.phase, .idle)
            XCTAssertEqual(checker.hasNoPublishedRelease, false)
            XCTAssertTrue(checker.lastChecked != nil)

            // Relaunching during the API cooldown must continue using the public endpoint.
            let relaunched = UpdateChecker(defaults: defaults, request: request)
            await relaunched.check()
            XCTAssertEqual(relaunched.latest?.version, "1.2.1")
            XCTAssertEqual(apiRequests, 1)
            XCTAssertEqual(publicRequests, 4)
        }
    }

    func testOldTimestampAndFailedCheckDoNotMeanNoRelease() async {
        let suite = "usagebar-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousCheck = Date(timeIntervalSince1970: 1234567890)
        defaults.set(previousCheck, forKey: "updateLastChecked")
        let checker = UpdateChecker(defaults: defaults) { url, _ in response(url, 503) }
        XCTAssertEqual(checker.hasNoPublishedRelease, false)
        await checker.check()
        XCTAssertEqual(checker.hasNoPublishedRelease, false)
        XCTAssertEqual(checker.lastChecked, previousCheck)
        if case .failed = checker.phase {} else { XCTAssertTrue(false) }
    }

    func testNoReleaseRequiresSuccessfulCheck() async {
        let suite = "usagebar-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var status = 404
        let checker = UpdateChecker(defaults: defaults) { url, _ in response(url, status) }
        await checker.check()
        XCTAssertEqual(checker.hasNoPublishedRelease, true)
        XCTAssertEqual(checker.phase, .idle)
        status = 503
        await checker.check()
        XCTAssertEqual(checker.hasNoPublishedRelease, false)
    }

    func testSuccessfulAPICheckKeepsReleaseNotesAndMatchingChecksum() async {
        let suite = "usagebar-update-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let checker = UpdateChecker(defaults: defaults) { url, _ in
            requests += 1
            return response(url, 200, """
            {"tag_name":"v1.2.1","html_url":"\(page)","body":"New logo and reliable updates.","assets":[
              {"name":"other.sha256","browser_download_url":"https://github.com/kubilayege/UsageBar/releases/download/v1.2.1/other.sha256"},
              {"name":"UsageBar-1.2.1-arm64.dmg","browser_download_url":"\(dmg)"},
              {"name":"UsageBar-1.2.1-arm64.dmg.sha256","browser_download_url":"\(dmg).sha256"}
            ]}
            """)
        }
        await checker.check()
        XCTAssertEqual(checker.latest?.version, "1.2.1")
        XCTAssertEqual(checker.latest?.notes, "New logo and reliable updates.")
        XCTAssertEqual(checker.latest?.checksum?.absoluteString, dmg + ".sha256")
        XCTAssertEqual(requests, 1)
    }

    func testBrokenPublicFallbackIsAnErrorNotNoRelease() async {
        for invalidPage in [true, false] {
            let suite = "usagebar-update-tests-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let checker = UpdateChecker(defaults: defaults) { url, _ in
                if url.host == "api.github.com" { return response(url, 403) }
                if url.lastPathComponent == "latest" {
                    return response(invalidPage ? URL(string: "https://github.com/login")! : page, 200)
                }
                return response(url, 200, #"<a href="https://example.com/other.dmg">Unrelated file</a>"#)
            }
            await checker.check()
            XCTAssertEqual(checker.latest, nil)
            XCTAssertEqual(checker.hasNoPublishedRelease, false)
            XCTAssertEqual(checker.lastChecked, nil)
            if case .failed = checker.phase {} else { XCTAssertTrue(false) }
        }
    }
}
