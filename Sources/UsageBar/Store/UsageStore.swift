import Foundation
import Combine
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    /// Keyed by `Account.id`.
    @Published private(set) var states: [String: ProviderState] = [:]
    @Published private(set) var accountsByProvider: [ProviderID: [Account]] = [:]
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
    private var popoverShown = false
    private var dashboardPresence = Presence.hidden
    private var statusesFetchedAt: Date?
    private var isScanningActivity = false

    /// Rate-limit hygiene: each account has a floor on how often we hit its endpoint,
    /// and a 429 doubles that floor (up to 16x) until a few refreshes succeed again.
    private var nextAllowed: [String: Date] = [:]
    private var backoffExponent: [String: Int] = [:]
    private var successStreak: [String: Int] = [:]
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

    private func effectiveInterval(_ a: Account) -> TimeInterval {
        let base = max(TimeInterval(settings.refreshInterval), minInterval(a.provider))
        return base * pow(2, Double(backoffExponent[a.id] ?? 0))
    }

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        reloadAccounts()
        loadPersistedSnapshots()
        Task { await sleepControl.refresh() }
        notifier.requestAuthorization()

        settings.$refreshInterval.dropFirst().sink { [weak self] _ in self?.scheduleRefreshTimer() }.store(in: &cancellables)
        settings.$enabledProviders.dropFirst().removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            for id in ProviderID.allCases where !enabled.contains(id) {
                for a in self.accounts(for: id) { self.states[a.id] = nil }
            }
            if let f = self.filter, !enabled.contains(f) { self.filter = nil }
            Task { await self.refreshAll() }
        }.store(in: &cancellables)
        Publishers.MergeMany(
            settings.$claudeFolders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$codexFolders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$ignoredAccountFolders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$rememberCodexAccounts.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in
            guard let self else { return }
            self.reloadAccounts()
            Task { await self.refreshAll() }
        }.store(in: &cancellables)
        settings.$accountNicknames.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reloadAccounts() }
        }.store(in: &cancellables)

        scheduleRefreshTimer()
        Task { await refreshAll() }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = repeating(TimeInterval(max(10, settings.refreshInterval))) { await $0.refreshAll() }
    }

    /// Tolerance lets macOS coalesce these wakeups with other timers instead of waking the CPU for each.
    private func repeating(_ interval: TimeInterval, _ body: @escaping @MainActor (UsageStore) async -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in if let self { await body(self) } }
        }
        timer.tolerance = interval * 0.2
        return timer
    }

    // MARK: Visibility

    /// Only the provider refresh (menu bar, history, alerts) runs in the background. The clock,
    /// live sessions, sleep state, log scans and status pages feed the popover and dashboard only,
    /// so they run while one of those is on screen.
    enum Presence { case hidden, background, focused }

    var isUIVisible: Bool { popoverShown || dashboardPresence != .hidden }

    func setPopoverShown(_ shown: Bool) {
        guard shown != popoverShown else { return }
        popoverShown = shown
        updateUIWork(refresh: shown)
    }

    func setDashboardPresence(_ presence: Presence) {
        guard presence != dashboardPresence else { return }
        let appeared = dashboardPresence == .hidden
        dashboardPresence = presence
        updateUIWork(refresh: appeared && presence != .hidden)
    }

    /// Seconds between clock ticks: every second in the popover, slower for a dashboard left open.
    private var clockCadence: TimeInterval? {
        if popoverShown { return 1 }
        switch dashboardPresence {
        case .focused: return 5
        case .background: return 30
        case .hidden: return nil
        }
    }

    private func updateUIWork(refresh: Bool) {
        let cadence = clockCadence
        if clockTimer?.timeInterval != cadence {
            clockTimer?.invalidate()
            clockTimer = nil
            if let cadence {
                now = Date()
                clockTimer = repeating(cadence) { $0.now = Date() }
            }
        }
        guard isUIVisible else {
            liveTimer?.invalidate(); liveTimer = nil
            activityTimer?.invalidate(); activityTimer = nil
            return
        }
        if refresh {
            refreshLiveSessions()
            Task { await sleepControl.refresh() }
            scanActivity(ifOlderThan: 300)
            WorkLogState.shared.scan(ifOlderThan: 60)
            refreshStatuses(ifOlderThan: 120)
        }
        if liveTimer == nil {
            liveTimer = repeating(15) { store in
                store.refreshLiveSessions()
                await store.sleepControl.refresh()
            }
        }
        if activityTimer == nil {
            activityTimer = repeating(300) { store in
                store.scanActivity()
                WorkLogState.shared.scan()
            }
        }
    }

    // MARK: Refresh

    /// Re-reads config folders and auth files. Cheap: a handful of small local files.
    func reloadAccounts() {
        let found = AccountDirectory.discover(settings.accountOptions)
        if found != accountsByProvider { accountsByProvider = found }
        let ids = Set(accountsByProvider.values.flatMap { $0 }.map(\.id))
        for key in states.keys where !ids.contains(key) { states[key] = nil }
    }

    func accounts(for id: ProviderID) -> [Account] {
        accountsByProvider[id] ?? [Account(provider: id, key: nil, source: .standard)]
    }

    /// Every account of every enabled provider, in provider order.
    var enabledAccounts: [Account] { settings.orderedEnabledProviders.flatMap(accounts(for:)) }

    var visibleAccounts: [Account] {
        if let filter { return accounts(for: filter) }
        return enabledAccounts
    }

    func hasSeveralAccounts(_ id: ProviderID) -> Bool { accounts(for: id).count > 1 }

    /// The account's name in the UI: its nickname, the part of its email before the @ when
    /// no sibling shares it, the whole email, or "Account 2".
    func label(_ a: Account) -> String {
        if let nickname = a.nickname { return nickname }
        let siblings = accounts(for: a.provider)
        if let email = a.email {
            let local = String(email.prefix { $0 != "@" })
            let clash = siblings.contains { $0.id != a.id && $0.nickname == nil && $0.email.map { String($0.prefix { $0 != "@" }) } == local }
            return local.isEmpty || clash ? email : local
        }
        return "Account \((siblings.firstIndex(of: a) ?? 0) + 1)"
    }

    /// "Codex" when it's the only account, "Codex · work" otherwise.
    func title(_ a: Account) -> String {
        hasSeveralAccounts(a.provider) ? "\(a.provider.displayName) · \(label(a))" : a.provider.displayName
    }

    /// Menu bar code: X for the first Codex account, X2 for the second.
    func shortCode(_ a: Account) -> String {
        let index = accounts(for: a.provider).firstIndex(of: a) ?? 0
        return index == 0 ? a.provider.shortCode : "\(a.provider.shortCode)\(index + 1)"
    }

    func runwaySources(_ accounts: [Account]) -> [Runway.Source] {
        accounts.compactMap { a in snapshot(a).map { Runway.Source(id: a.id, title: title(a), snapshot: $0) } }
    }

    func forgetSavedAccount(_ a: Account) {
        guard a.source == .saved, let key = a.key else { return }
        AccountDirectory.forget(key)
        settings.accountNicknames[a.id] = nil
        reloadAccounts()
    }

    private func provider(for a: Account) -> any UsageProvider {
        switch a.provider {
        case .claude: return ClaudeProvider(configDir: a.claudeConfigDir, email: a.email)
        case .codex: return CodexProvider(credential: a.codex, isSaved: a.source == .saved)
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

        reloadAccounts()
        let now = Date()
        let due = enabledAccounts.filter { a in
            if let until = states[a.id]?.cooldownUntil, until > now { return false }
            if force {
                // Manual refresh: still never hammer an endpoint more than once per 15s.
                if let last = states[a.id]?.snapshot?.fetchedAt, now.timeIntervalSince(last) < 15 { return false }
                return true
            }
            return (nextAllowed[a.id] ?? .distantPast) <= now
        }
        for a in due { states[a.id] = .loading(stale: states[a.id]?.snapshot) }

        let statusTask = isUIVisible || force ? Task { await fetchStatuses() } : nil

        await withTaskGroup(of: (Account, Result<UsageSnapshot, Error>).self) { group in
            for (i, a) in due.enumerated() {
                let p = provider(for: a)
                group.addTask {
                    // Stagger requests slightly so we don't burst every endpoint at once.
                    try? await Task.sleep(nanoseconds: UInt64(i) * 120_000_000)
                    do { return (a, .success(try await p.fetch())) } catch { return (a, .failure(error)) }
                }
            }
            for await (a, result) in group { apply(a, result) }
        }
        await statusTask?.value
        // With no clock running in the background, this is what moves `now` for the menu bar's pace mark.
        self.now = Date()
        lastRefresh = self.now
        refreshLiveSessions()
    }

    private func fetchStatuses() async {
        statusesFetchedAt = Date()
        serviceStatuses = await StatusPageService.fetchAll(settings.orderedEnabledProviders.compactMap(\.statusService))
    }

    private func refreshStatuses(ifOlderThan age: TimeInterval) {
        if let at = statusesFetchedAt, Date().timeIntervalSince(at) < age { return }
        Task { await fetchStatuses() }
    }

    func refreshLiveSessions() {
        guard settings.showLiveSessions else { liveSessions = []; return }
        guard isUIVisible else { return }
        guard liveScanTask == nil else { return }
        liveScanTask = Task {
            let sessions = await Task.detached(priority: .utility) { LiveSessionScanner.scan() }.value
            liveSessions = settings.showLiveSessions ? sessions : []
            liveScanTask = nil
        }
    }

    func refresh(_ a: Account) async {
        if let until = states[a.id]?.cooldownUntil, until > Date() { return }
        states[a.id] = .loading(stale: states[a.id]?.snapshot)
        let p = provider(for: a)
        do { apply(a, .success(try await p.fetch())) } catch { apply(a, .failure(error)) }
    }

    private func apply(_ a: Account, _ result: Result<UsageSnapshot, Error>) {
        let id = a.id
        let stale = states[id]?.snapshot
        switch result {
        case .success(let snap):
            states[id] = .ready(snap)
            history.record(snap, account: a.key)
            notifier.evaluate(old: stale, new: snap, name: title(a), source: id, settings: settings)
            successStreak[id, default: 0] += 1
            if successStreak[id, default: 0] >= 3 { backoffExponent[id] = 0 }
            nextAllowed[id] = Date().addingTimeInterval(effectiveInterval(a))
            persistSnapshots()
        case .failure(let error):
            if let pe = error as? ProviderError, pe.kind == .notConfigured {
                states[id] = .notConfigured(pe.message)
            } else if let pe = error as? ProviderError, pe.kind == .rateLimited {
                successStreak[id] = 0
                backoffExponent[id] = min((backoffExponent[id] ?? 0) + 1, 4)
                let wait = max(pe.retryAfter ?? 0, effectiveInterval(a))
                states[id] = .cooldown(until: Date().addingTimeInterval(wait), stale: stale)
                nextAllowed[id] = Date().addingTimeInterval(wait)
            } else {
                // An expired saved sign-in only changes when you sign in again; don't retry it every 30s.
                let savedExpired = a.source == .saved && (a.codex?.isExpired ?? false)
                nextAllowed[id] = Date().addingTimeInterval(savedExpired ? 1800 : max(30, minInterval(a.provider) / 2))
                states[id] = .error(error.localizedDescription, stale: stale)
            }
        }
    }

    // MARK: Persistence (last good snapshot per account, so relaunches don't refetch or go blank)

    private func persistSnapshots() {
        var dict: [String: UsageSnapshot] = [:]
        for (id, state) in states { if let s = state.snapshot { dict[id] = s } }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let data = try? enc.encode(dict) { try? data.write(to: snapshotsURL, options: .atomic) }
    }

    private func loadPersistedSnapshots() {
        guard let data = FileManager.default.contents(atPath: snapshotsURL.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let dict = try? dec.decode([String: UsageSnapshot].self, from: data) else { return }
        let accounts = Dictionary(enabledAccounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, snap) in dict {
            guard let a = accounts[id] else { continue }
            // Ignore anything older than a day; the windows will have rolled over.
            guard Date().timeIntervalSince(snap.fetchedAt) < 86400 else { continue }
            states[id] = .ready(snap)
            nextAllowed[id] = snap.fetchedAt.addingTimeInterval(effectiveInterval(a))
        }
    }

    private func scanActivity(ifOlderThan age: TimeInterval = 0) {
        guard !isScanningActivity else { return }
        if let at = activity?.scannedAt, Date().timeIntervalSince(at) < age { return }
        isScanningActivity = true
        Task {
            activity = await Task.detached(priority: .utility) { ActivityScanner.scan() }.value
            isScanningActivity = false
        }
    }

    // MARK: Derived

    func state(_ a: Account) -> ProviderState { states[a.id] ?? .idle }
    func snapshot(_ a: Account) -> UsageSnapshot? { states[a.id]?.snapshot }
    func snapshots(_ id: ProviderID) -> [UsageSnapshot] { accounts(for: id).compactMap(snapshot) }

    /// Worst severity across all enabled accounts.
    var overallSeverity: Severity {
        enabledAccounts.compactMap { snapshot($0)?.worstSeverity }.max() ?? .ok
    }

    var menuBarSegments: [MenuBarSegment] {
        guard settings.menuBarMode != .icon else { return [] }
        var out: [MenuBarSegment] = []
        for account in enabledAccounts {
            let code = shortCode(account)
            guard let snap = snapshot(account) else { continue }
            let windows = snap.primaryWindows.filter(\.hasLimit)
            guard !windows.isEmpty else { continue }
            let sev = windows.map(\.severity).max() ?? .ok
            var text: String
            switch settings.menuBarMode {
            case .full:
                if windows.count >= 2 {
                    text = "\(code):" + windows.prefix(2).map { Format.percent($0.percent) }.joined(separator: "/")
                } else {
                    let w = windows[0]
                    let short = w.label == "Monthly" ? "Mo" : (w.label == "Weekly" ? "Wk" : w.label)
                    text = "\(code):\(short) \(Format.percent(w.percent))"
                }
            default:
                text = "\(code) " + windows.prefix(2).map { "\(Int($0.percent.rounded()))" }.joined(separator: "/")
            }
            if settings.showPaceInMenuBar, let pace = snap.paceWindow?.paceVerdict(now: now), pace != .healthy {
                text += pace == .over ? " ⚠︎" : " ↗"
            }
            out.append(MenuBarSegment(id: account.id, dot: account.provider.color, text: text, color: sev.color))
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
        let work = Account(provider: .codex, key: "demo-work", source: .standard, email: "kubilay@joygame.com", nickname: "Work")
        let personal = Account(provider: .codex, key: "demo-personal", source: .saved, email: "kege@example.com")
        accountsByProvider = [.codex: [work, personal]]
        states[ProviderID.claude.rawValue] = .ready(UsageSnapshot(provider: .claude, windows: [
            win("5h", "5h", 87, 5 * 3600, 4 * 3600 + 7 * 60), win("7d", "7d", 71, 7 * 86400, 20 * 3600 + 17 * 60)],
            planName: "Max", extraUsage: ExtraUsage(title: "Extra", used: 12.4, limit: 50, utilization: nil, currency: "USD")))
        states[work.id] = .ready(UsageSnapshot(provider: .codex, windows: [
            win("5h", "5h", 34, 5 * 3600, 2 * 3600 + 12 * 60), win("7d", "7d", 100, 7 * 86400, 5 * 86400 + 8 * 3600)],
            planName: "Pro", accountLabel: work.email, bankedResets: BankedResets(available: 2, applicable: 1)))
        states[personal.id] = .ready(UsageSnapshot(provider: .codex, windows: [
            win("5h", "5h", 12, 5 * 3600, 3 * 3600 + 40 * 60), win("7d", "7d", 46, 7 * 86400, 2 * 86400 + 5 * 3600)],
            planName: "Plus", accountLabel: personal.email))
        states[ProviderID.cursor.rawValue] = .ready(UsageSnapshot(provider: .cursor, windows: [
            UsageWindow(id: "monthly", label: "Monthly", percent: 58, resetsAt: now.addingTimeInterval(12 * 86400 + 19 * 3600),
                        windowDuration: 30 * 86400, detail: "$11.60 / $20")], planName: "Pro"))
        states[ProviderID.opencode.rawValue] = .ready(UsageSnapshot(provider: .opencode, windows: [
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
