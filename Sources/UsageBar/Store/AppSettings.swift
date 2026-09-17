import Foundation
import Combine
import ServiceManagement

enum MenuBarMode: String, CaseIterable, Identifiable {
    case full, compact, icon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Full (C:87%/71% • X:7d 100%)"
        case .compact: return "Compact (C 87 · X 100)"
        case .icon: return "Icon only"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings(defaults: RenderFlags.isRendering ? UserDefaults(suiteName: "com.kubilay.usagebar.preview")! : .standard)
    private let d: UserDefaults
    static let refreshChoices = [12, 30, 60, 300]

    @Published var enabledProviders: Set<ProviderID> { didSet { d.set(enabledProviders.map(\.rawValue).sorted(), forKey: "enabledProviders") } }
    @Published var refreshInterval: Int { didSet { d.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var compactPopover: Bool { didSet { d.set(compactPopover, forKey: "compactPopover") } }
    @Published var menuBarMode: MenuBarMode { didSet { d.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var showPaceInMenuBar: Bool { didSet { d.set(showPaceInMenuBar, forKey: "showPaceInMenuBar") } }
    @Published var notificationsEnabled: Bool { didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") } }
    @Published var notifyThresholds: Bool { didSet { d.set(notifyThresholds, forKey: "notifyThresholds") } }
    @Published var notifyResets: Bool { didSet { d.set(notifyResets, forKey: "notifyResets") } }
    @Published var opencodeDailyTokenBudget: Int { didSet { d.set(opencodeDailyTokenBudget, forKey: "opencodeDailyTokenBudget") } }
    @Published var showLiveSessions: Bool { didSet { d.set(showLiveSessions, forKey: "showLiveSessions") } }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin"); applyLaunchAtLogin() } }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        let stored = d.stringArray(forKey: "enabledProviders")?.compactMap(ProviderID.init(rawValue:))
        enabledProviders = stored.map(Set.init) ?? [.claude, .codex, .cursor, .opencode]
        refreshInterval = d.object(forKey: "refreshInterval") as? Int ?? 30
        compactPopover = d.bool(forKey: "compactPopover")
        menuBarMode = MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .icon
        showPaceInMenuBar = d.object(forKey: "showPaceInMenuBar") as? Bool ?? true
        notificationsEnabled = d.object(forKey: "notificationsEnabled") as? Bool ?? true
        notifyThresholds = d.object(forKey: "notifyThresholds") as? Bool ?? true
        notifyResets = d.object(forKey: "notifyResets") as? Bool ?? true
        opencodeDailyTokenBudget = d.integer(forKey: "opencodeDailyTokenBudget")
        showLiveSessions = d.object(forKey: "showLiveSessions") as? Bool ?? true
        launchAtLogin = d.bool(forKey: "launchAtLogin")
    }

    var orderedEnabledProviders: [ProviderID] {
        ProviderID.allCases.filter { enabledProviders.contains($0) }
    }

    func toggle(_ p: ProviderID) {
        if enabledProviders.contains(p) { enabledProviders.remove(p) } else { enabledProviders.insert(p) }
    }

    func cycleRefreshInterval() {
        let choices = Self.refreshChoices
        if let i = choices.firstIndex(of: refreshInterval) {
            refreshInterval = choices[(i + 1) % choices.count]
        } else {
            refreshInterval = choices[0]
        }
    }

    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    private func applyLaunchAtLogin() {
        guard Self.isBundled else { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
    }
}
