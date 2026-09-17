import AppKit
import Combine
import Sparkle

/// Sparkle owns the update feed, download, signature verification, installation, and relaunch.
/// This adapter exposes its state to SwiftUI without starting an updater in previews or tests.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateChecker()
    static let repository = "kubilayege/UsageBar"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }
    static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    enum Phase: Equatable { case idle, checking, noUpdate, available, failed(String) }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var availableVersion: String?
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastChecked: Date?

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    var isUpdateAvailable: Bool { availableVersion != nil }
    var isEnabled: Bool { controller != nil }

    /// Migrate once before Sparkle reads its preferences. Never overwrite a Sparkle choice.
    static func migratePreferences(in defaults: UserDefaults) {
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
           let legacy = defaults.object(forKey: "checkForUpdates") as? Bool {
            defaults.set(legacy, forKey: "SUEnableAutomaticChecks")
        }
    }

    func start() {
        guard controller == nil, AppSettings.isBundled, !RenderFlags.isRendering else { return }
        Self.migratePreferences(in: .standard)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in self?.lastChecked = updater.lastUpdateCheckDate }
            },
        ]
        do {
            try updater.start()
        } catch {
            phase = .failed(error.localizedDescription)
            canCheckForUpdates = false
        }
    }

    func check() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        phase = .checking
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        phase = .available
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        availableVersion = nil
        phase = .noUpdate
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            availableVersion = nil
            phase = .idle
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain,
           [SUError.noUpdateError.rawValue, SUError.installationCanceledError.rawValue].contains(OSStatus(error.code)) { return }
        phase = .failed(error.localizedDescription)
    }

    // Keep scheduled reminders in the menu bar until the user chooses to review the update.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor [weak self] in
            self?.availableVersion = version
            self?.phase = .available
        }
    }
}
