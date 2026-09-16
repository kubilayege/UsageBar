import Foundation
import Combine
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var states: [ProviderID: ProviderState] = [:]
    @Published private(set) var serviceStatuses: [ServiceStatus] = []
    @Published private(set) var now = Date()
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var activity: ActivityData?
    @Published private(set) var liveSessions: [LiveSession] = []
    @Published var filter: ProviderID?
    @Published var dashboardTab: DashboardTab = .overview

    let settings = AppSettings.shared
    let history = HistoryStore()
    let notifier = Notifier()
    let sleepControl = SleepControl.shared
    private var liveScanTask: Task<Void, Never>?
    private var liveTimer: Timer?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var activityTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Rate-limit hygiene: each provider has a floor on how often we hit its endpoint,
    /// and a 429 doubles that floor (up to 16x) until a few refreshes succeed again.
    private var nextAllowed: [ProviderID: Date] = [:]
    private var backoffExponent: [ProviderID: Int] = [:]
    private var successStreak: [ProviderID: Int] = [:]
    private let snapshotsURL = Files.appSupport.appendingPathComponent("snapshots.json")

    private func minInterval(_ id: ProviderID) -> TimeInterval {
        switch id {
        case .claude: return 120      // Anthropic's OAuth usage endpoint rate-limits quickly
        case .codex: return 60
        case .cursor: return 60
        case .gemini: return 300
        case .antigravity: return 30
        case .opencode: return 15     // local database, cheap
        }
    }

    private func effectiveInterval(_ id: ProviderID) -> TimeInterval {
        let base = max(TimeInterval(settings.refreshInterval), minInterval(id))
        return base * pow(2, Double(backoffExponent[id] ?? 0))
    }

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadPersistedSnapshots()
        Task { await sleepControl.refresh() }
        notifier.requestAuthorization()

        settings.$refreshInterval.dropFirst().sink { [weak self] _ in self?.scheduleRefreshTimer() }.store(in: &cancellables)
        settings.$enabledProviders.dropFirst().removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            for id in ProviderID.allCases where !enabled.contains(id) { self.states[id] = nil }
            if let f = self.filter, !enabled.contains(f) { self.filter = nil }
            Task { await self.refreshAll() }
        }.store(in: &cancellables)

        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLiveSessions()
                await self?.sleepControl.refresh()
            }
        }
        refreshLiveSessions()
        scheduleRefreshTimer()
        Task { await refreshAll() }
        scanActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanActivity() }
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(10, settings.refreshInterval))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshAll() }
        }
    }

    // MARK: Refresh

    private func provider(for id: ProviderID) -> any UsageProvider {
        switch id {
        case .claude: return ClaudeProvider()
        case .codex: return CodexProvider()
        case .cursor: return CursorProvider()
        case .gemini: return GeminiProvider()
        case .antigravity: return AntigravityProvider()
        case .opencode: return OpenCodeProvider(dailyTokenBudget: settings.opencodeDailyTokenBudget)
        }
    }

    func refreshAll(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        let ids = settings.orderedEnabledProviders.filter { id in
            if let until = states[id]?.cooldownUntil, until > now { return false }
            if force {
                // Manual refresh: still never hammer an endpoint more than once per 15s.
                if let last = states[id]?.snapshot?.fetchedAt, now.timeIntervalSince(last) < 15 { return false }
                return true
            }
            return (nextAllowed[id] ?? .distantPast) <= now
        }
        for id in ids { states[id] = .loading(stale: states[id]?.snapshot) }

        let statusServices = settings.orderedEnabledProviders.compactMap(\.statusService)
        let statusTask = Task { await StatusPageService.fetchAll(statusServices) }

        await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, Error>).self) { group in
            for (i, id) in ids.enumerated() {
                let p = provider(for: id)
                group.addTask {
                    // Stagger requests slightly so we don't burst every endpoint at once.
                    try? await Task.sleep(nanoseconds: UInt64(i) * 120_000_000)
                    do { return (id, .success(try await p.fetch())) } catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group { apply(id, result) }
        }
        serviceStatuses = await statusTask.value
        lastRefresh = Date()
        refreshLiveSessions()
    }

    func refreshLiveSessions() {
        guard settings.showLiveSessions else { liveSessions = []; return }
        guard liveScanTask == nil else { return }
        liveScanTask = Task {
            let sessions = await Task.detached(priority: .utility) { LiveSessionScanner.scan() }.value
            liveSessions = settings.showLiveSessions ? sessions : []
            liveScanTask = nil
        }
    }

    func refresh(_ id: ProviderID) async {
        if let until = states[id]?.cooldownUntil, until > Date() { return }
        states[id] = .loading(stale: states[id]?.snapshot)
        let p = provider(for: id)
        do { apply(id, .success(try await p.fetch())) } catch { apply(id, .failure(error)) }
    }

    private func apply(_ id: ProviderID, _ result: Result<UsageSnapshot, Error>) {
        let stale = states[id]?.snapshot
        switch result {
        case .success(let snap):
            states[id] = .ready(snap)
            history.record(snap)
            notifier.evaluate(old: stale, new: snap, settings: settings)
            successStreak[id, default: 0] += 1
            if successStreak[id, default: 0] >= 3 { backoffExponent[id] = 0 }
            nextAllowed[id] = Date().addingTimeInterval(effectiveInterval(id))
            persistSnapshots()
        case .failure(let error):
            if let pe = error as? ProviderError, pe.kind == .notConfigured {
                states[id] = .notConfigured(pe.message)
            } else if let pe = error as? ProviderError, pe.kind == .rateLimited {
                successStreak[id] = 0
                backoffExponent[id] = min((backoffExponent[id] ?? 0) + 1, 4)
                let wait = max(pe.retryAfter ?? 0, effectiveInterval(id))
                states[id] = .cooldown(until: Date().addingTimeInterval(wait), stale: stale)
                nextAllowed[id] = Date().addingTimeInterval(wait)
            } else {
                nextAllowed[id] = Date().addingTimeInterval(max(30, minInterval(id) / 2))
                states[id] = .error(error.localizedDescription, stale: stale)
            }
        }
    }

    // MARK: Persistence (last good snapshot per provider, so relaunches don't refetch or go blank)

    private func persistSnapshots() {
        var dict: [String: UsageSnapshot] = [:]
        for (id, state) in states { if let s = state.snapshot { dict[id.rawValue] = s } }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(dict) { try? data.write(to: snapshotsURL, options: .atomic) }
    }

    private func loadPersistedSnapshots() {
        guard let data = FileManager.default.contents(atPath: snapshotsURL.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let dict = try? dec.decode([String: UsageSnapshot].self, from: data) else { return }
        for (raw, snap) in dict {
            guard let id = ProviderID(rawValue: raw), settings.enabledProviders.contains(id) else { continue }
            // Ignore anything older than a day; the windows will have rolled over.
            guard Date().timeIntervalSince(snap.fetchedAt) < 86400 else { continue }
            states[id] = .ready(snap)
            nextAllowed[id] = snap.fetchedAt.addingTimeInterval(effectiveInterval(id))
        }
    }

    private func scanActivity() {
        Task.detached(priority: .utility) {
            let data = ActivityScanner.scan()
            await MainActor.run { UsageStore.shared.activity = data }
        }
    }

    // MARK: Derived

    func state(_ id: ProviderID) -> ProviderState { states[id] ?? .idle }
    func snapshot(_ id: ProviderID) -> UsageSnapshot? { states[id]?.snapshot }

    var visibleProviders: [ProviderID] {
        if let filter { return [filter] }
        return settings.orderedEnabledProviders
    }

    /// Worst severity across all enabled providers.
    var overallSeverity: Severity {
        settings.orderedEnabledProviders.compactMap { snapshot($0)?.worstSeverity }.max() ?? .ok
    }

    var menuBarSegments: [MenuBarSegment] {
        guard settings.menuBarMode != .icon else { return [] }
        var out: [MenuBarSegment] = []
        for id in settings.orderedEnabledProviders {
            guard let snap = snapshot(id) else { continue }
            let windows = snap.primaryWindows.filter(\.hasLimit)
            guard !windows.isEmpty else { continue }
            let sev = windows.map(\.severity).max() ?? .ok
            var text: String
            switch settings.menuBarMode {
            case .full:
                if windows.count >= 2 {
                    text = "\(id.shortCode):" + windows.prefix(2).map { Format.percent($0.percent) }.joined(separator: "/")
                } else {
                    let w = windows[0]
                    let short = w.label == "Monthly" ? "Mo" : (w.label == "Weekly" ? "Wk" : w.label)
                    text = "\(id.shortCode):\(short) \(Format.percent(w.percent))"
                }
            default:
                text = "\(id.shortCode) " + windows.prefix(2).map { "\(Int($0.percent.rounded()))" }.joined(separator: "/")
            }
            if settings.showPaceInMenuBar, let pace = snap.paceWindow?.paceVerdict(now: now), pace != .healthy {
                text += pace == .over ? " ⚠︎" : " ↗"
            }
            out.append(MenuBarSegment(id: id.rawValue, dot: id.color, text: text, color: sev.color))
        }
        return out
    }

    // MARK: Demo data (used for --render-preview)

    func loadRealActivityForPreview() {
        activity = ActivityScanner.scan()
        liveSessions = LiveSessionScanner.scan()
    }

    func loadDemoData() {
        let now = Date()
        func win(_ id: String, _ label: String, _ pct: Double, _ dur: TimeInterval, _ remaining: TimeInterval, primary: Bool = true) -> UsageWindow {
            UsageWindow(id: id, label: label, percent: pct, resetsAt: now.addingTimeInterval(remaining), windowDuration: dur, isPrimary: primary)
        }
        states[.claude] = .ready(UsageSnapshot(provider: .claude, windows: [
            win("5h", "5h", 87, 5 * 3600, 4 * 3600 + 7 * 60), win("7d", "7d", 71, 7 * 86400, 20 * 3600 + 17 * 60)],
            planName: "Max", extraUsage: ExtraUsage(title: "Extra", used: 12.4, limit: 50, utilization: nil, currency: "USD")))
        states[.codex] = .ready(UsageSnapshot(provider: .codex, windows: [
            win("5h", "5h", 34, 5 * 3600, 2 * 3600 + 12 * 60), win("7d", "7d", 100, 7 * 86400, 5 * 86400 + 8 * 3600)],
            planName: "Pro", bankedResets: BankedResets(available: 2, applicable: 1)))
        states[.cursor] = .ready(UsageSnapshot(provider: .cursor, windows: [
            UsageWindow(id: "monthly", label: "Monthly", percent: 58, resetsAt: now.addingTimeInterval(12 * 86400 + 19 * 3600),
                        windowDuration: 30 * 86400, detail: "$11.60 / $20")], planName: "Pro"))
        states[.opencode] = .ready(UsageSnapshot(provider: .opencode, windows: [
            UsageWindow(id: "today", label: "Today", percent: 0, resetsAt: nil, windowDuration: nil, detail: "1.2M tok · $0", hasLimit: false),
            UsageWindow(id: "7d", label: "7d", percent: 0, resetsAt: nil, windowDuration: nil, detail: "8.4M tok · $0", hasLimit: false)],
            planName: "Go"))
        serviceStatuses = [
            ServiceStatus(service: .claude, indicator: "none", description: "All Systems Operational"),
            ServiceStatus(service: .openai, indicator: "none", description: "All Systems Operational"),
            ServiceStatus(service: .cursor, indicator: "minor", description: "Partial degradation"),
        ]
        lastRefresh = now
        liveSessions = [
            LiveSession(id: "1", provider: .claude, project: "UsageBar", cwd: "~/Personal/Projects/UsageBar", model: "fable-5-1", branch: "main",
                        tokens: 98_400, tokensLabel: "ctx", lastActivity: now.addingTimeInterval(-40), isProcessRunning: true),
            LiveSession(id: "2", provider: .codex, project: "funjitsu-mobile-template", cwd: "~/Joygame/funjitsu-mobile-template", model: "gpt-5.3-codex", branch: nil,
                        tokens: 1_240_000, tokensLabel: "tok", lastActivity: now.addingTimeInterval(-6 * 60), isProcessRunning: false),
        ]
    }
}
