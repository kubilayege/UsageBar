import Foundation

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    /// Session for talking to local self-signed servers (Antigravity language server).
    static let insecureLocal: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        return URLSession(configuration: c, delegate: InsecureLocalhostDelegate(), delegateQueue: nil)
    }()

    static func request(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        session: URLSession = HTTP.session
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("UsageBar/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw ProviderError(.network, "Invalid response")
            }
            return (data, http)
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError(.network, "Network: \(error.localizedDescription)")
        }
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? ""
            throw ProviderError(.parse, "Unexpected response: \(preview)")
        }
        return obj
    }

    static func jsonBody(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }
}

final class InsecureLocalhostDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           ["127.0.0.1", "localhost", "::1"].contains(host),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Loose JSON helpers

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> JSON? { self[key] as? JSON }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func double(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let i = self[key] as? Int { return Double(i) }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let d = self[key] as? Double { return Int(d) }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
}

enum Files {
    static var home: String { NSHomeDirectory() }
    static var claudeRoot: String { ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? path(".claude") }
    static var codexRoot: String { ProcessInfo.processInfo.environment["CODEX_HOME"] ?? path(".codex") }
    static func path(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    static func readJSON(_ path: String) -> JSON? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSON
    }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("UsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum Shell {
    struct Result { var output: String; var error: String; var status: Int32 }

    /// Drain both pipes while the process runs so a full pipe cannot deadlock a scan.
    static func runResult(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return nil }
        final class Capture: @unchecked Sendable { var data = Data() }
        let stdout = Capture(), stderr = Capture(), drains = DispatchGroup()
        drains.enter()
        DispatchQueue.global().async { stdout.data = out.fileHandleForReading.readDataToEndOfFile(); drains.leave() }
        drains.enter()
        DispatchQueue.global().async { stderr.data = err.fileHandleForReading.readDataToEndOfFile(); drains.leave() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        guard drains.wait(timeout: .now() + 1) == .success else { return nil }
        return Result(output: String(decoding: stdout.data, as: UTF8.self),
                      error: String(decoding: stderr.data, as: UTF8.self), status: p.terminationStatus)
    }

    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5, requireSuccess: Bool = true) -> String? {
        guard let result = runResult(launchPath, args, timeout: timeout), !requireSuccess || result.status == 0 else { return nil }
        return result.output
    }
}
