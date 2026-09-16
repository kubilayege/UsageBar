import Foundation
import AppKit
import Combine
import CryptoKit

/// Checks GitHub releases for a newer build and downloads the DMG on request.
/// Only the public releases endpoint is contacted, and only if automatic checks are on or the user asks.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repository = "kubilayege/UsageBar"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    private static var latestAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }
    private static let interval: TimeInterval = 24 * 3600

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL
        var checksum: URL?
        var published: Date?
    }
    enum Phase: Equatable { case idle, checking, downloading(Double), verifying, opened(URL), failed(String) }

    @Published private(set) var latest: Release?
    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastChecked: Date?
    private var timer: Timer?

    private init() {
        lastChecked = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date
    }

    static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    var isUpdateAvailable: Bool {
        guard let latest, let current = Self.currentVersion else { return false }
        return Self.compare(latest.version, current) == .orderedDescending
    }

    /// Numeric dotted versions: 1.2.0 < 1.10.0; a leading "v" and pre-release suffixes are ignored.
    nonisolated static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            let core = s.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }.split(separator: "-").first ?? ""
            return core.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let l = parts(a), r = parts(b)
        for i in 0..<max(l.count, r.count) {
            let x = i < l.count ? l[i] : 0, y = i < r.count ? r[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Daily background check while the app runs; skipped for unbundled dev builds and previews.
    func startAutomaticChecks(settings: AppSettings) {
        guard AppSettings.isBundled, !RenderFlags.isRendering else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue(settings: settings) }
        }
        Task { try? await Task.sleep(nanoseconds: 15_000_000_000); await checkIfDue(settings: settings) }
    }

    private func checkIfDue(settings: AppSettings) async {
        guard settings.checkForUpdates else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        let wasAvailable = isUpdateAvailable
        await check()
        if isUpdateAvailable, !wasAvailable, let latest, settings.notificationsEnabled {
            Notifier().send(id: "update-\(latest.version)", title: "UsageBar \(latest.version) is available",
                            body: "Open Settings → Updates to download it.")
        }
    }

    func check() async {
        guard phase != .checking else { return }
        phase = .checking
        defer { if phase == .checking { phase = .idle } }
        do {
            let (data, response) = try await HTTP.request(Self.latestAPI, headers: ["X-GitHub-Api-Version": "2022-11-28"])
            guard response.statusCode != 404 else {
                latest = nil
                lastChecked = Date(); UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
                return
            }
            guard response.statusCode == 200 else { throw ProviderError(.network, "GitHub returned HTTP \(response.statusCode)") }
            let json = try HTTP.jsonObject(data)
            guard let tag = json.string("tag_name"), let page = json.string("html_url").flatMap(URL.init(string:)) else {
                throw ProviderError(.parse, "Release is missing a tag")
            }
            let assets = (json.array("assets") ?? []).compactMap { $0 as? JSON }
            func asset(_ suffix: String) -> URL? {
                assets.first { ($0.string("name") ?? "").hasSuffix(suffix) }?.string("browser_download_url").flatMap(URL.init(string:))
            }
            guard let dmg = asset(".dmg") else { throw ProviderError(.parse, "Release \(tag) has no DMG attached") }
            latest = Release(version: String(tag.drop { $0 == "v" }), notes: json.string("body") ?? "", page: page, dmg: dmg,
                             checksum: asset(".sha256"), published: Format.parseISO(json.string("published_at")))
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
            phase = .idle
        } catch {
            phase = .failed((error as? ProviderError)?.message ?? error.localizedDescription)
        }
    }

    /// Downloads the DMG to ~/Downloads, verifies the published SHA-256 when available, then mounts it.
    func downloadAndOpen() async {
        guard let latest, case .idle = phaseForDownload else { return }
        phase = .downloading(0)
        do {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
            let destination = downloads.appendingPathComponent(latest.dmg.lastPathComponent)
            let progress = Progress(totalUnitCount: 100)
            let observation = progress.observe(\.fractionCompleted) { [weak self] p, _ in
                Task { @MainActor in if case .downloading = self?.phase { self?.phase = .downloading(p.fractionCompleted) } }
            }
            defer { observation.invalidate() }
            let (temporary, response) = try await HTTP.session.download(from: latest.dmg, progress: progress)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError(.network, "Download failed") }
            if let checksum = latest.checksum {
                phase = .verifying
                let (expectedData, _) = try await HTTP.request(checksum)
                let expected = String(decoding: expectedData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
                let actual = SHA256.hash(data: try Data(contentsOf: temporary)).map { String(format: "%02x", $0) }.joined()
                guard expected.lowercased() == actual else {
                    try? FileManager.default.removeItem(at: temporary)
                    throw ProviderError(.parse, "Checksum mismatch; the download was discarded")
                }
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            NSWorkspace.shared.open(destination)
            phase = .opened(destination)
        } catch {
            phase = .failed((error as? ProviderError)?.message ?? error.localizedDescription)
        }
    }
    private var phaseForDownload: Phase {
        switch phase {
        case .downloading, .verifying, .checking: return phase
        default: return .idle
        }
    }
}

private extension URLSession {
    /// Async download with progress reporting; `download(from:)` offers no progress handle.
    func download(from url: URL, progress: Progress) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("UsageBar/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        return try await withCheckedThrowingContinuation { continuation in
            let task = downloadTask(with: request) { location, response, error in
                if let location, let response {
                    // The file is deleted when this closure returns, so move it first.
                    let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
                    do { try FileManager.default.moveItem(at: location, to: kept); continuation.resume(returning: (kept, response)) }
                    catch { continuation.resume(throwing: error) }
                } else {
                    continuation.resume(throwing: error ?? ProviderError(.network, "Download failed"))
                }
            }
            progress.addChild(task.progress, withPendingUnitCount: 100)
            task.resume()
        }
    }
}
