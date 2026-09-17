import SwiftUI
import AppKit
import Combine

#if !REGRESSION_TESTS
@main
#endif
struct UsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        PreviewRenderer.runIfRequested()
        Probe.runIfRequested()
        RevealProbe.runIfRequested()
    }

    var body: some Scene {
        // AppKit owns the menu bar item, popover and shared dashboard window.
        // This scene supplies commands; Settings opens a page in the dashboard.
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .usageBarOpenSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Usage") {
                Button("Open Dashboard") { NotificationCenter.default.post(name: .usageBarOpenDashboard, object: nil) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Show Usage Popup") { NotificationCenter.default.post(name: .usageBarTogglePopover, object: nil) }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Analyze Usage & Effort…") { NotificationCenter.default.post(name: .usageBarOpenAnalysis, object: nil) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppBranding.logo
        // A freshly opened build replaces older copies, preventing duplicate menu icons and cache writers.
        if let bundleID = Bundle.main.bundleIdentifier {
            let current = NSRunningApplication.current
            let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != current.processIdentifier }
            for peer in peers {
                if (peer.launchDate ?? .distantPast) > (current.launchDate ?? .distantPast) { NSApp.terminate(nil); return }
                peer.terminate()
            }
        }
        UsageStore.shared.start()
        statusItem = StatusItemController(store: UsageStore.shared)
        UpdateChecker.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DashboardWindowController.shared.show()
        return false
    }
}

// MARK: - Status item + popover

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var host: NSHostingController<AnyView>?
    private var lastTitle = NSAttributedString()
    private let whiteIcon = MenuBarIcon.whiteLogo()

    init(store: UsageStore) {
        self.store = store
        super.init()

        let host = NSHostingController(rootView: AnyView(PopoverView().environmentObject(store).environmentObject(store.settings)))
        self.host = host
        host.sizingOptions = []
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        }
        updateTitle()
        store.objectWillChange.merge(with: store.settings.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
        store.settings.$compactPopover.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sizePopover() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.popover.performClose(nil) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .usageBarTogglePopover)
            .sink { [weak self] _ in self?.togglePopover() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .usageBarOpenDashboard)
            .sink { [weak self] _ in self?.openDashboard() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .usageBarOpenAnalysis)
            .sink { [weak self] _ in self?.openAnalysis() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .usageBarOpenSettings)
            .sink { [weak self] _ in self?.openSettings() }
            .store(in: &cancellables)
    }

    func popoverWillShow(_ notification: Notification) {
        store.refreshLiveSessions()
        Task { await store.sleepControl.refresh() }
    }

    func popoverDidClose(_ notification: Notification) { updateTitle() }
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

    private func sizePopover() {
        guard let button = item.button else { return }
        let visibleHeight = button.window?.screen?.visibleFrame.height ?? 800
        let height = min(store.settings.compactPopover ? 560.0 : 720.0, max(240, visibleHeight - 24))
        host?.rootView = AnyView(PopoverView(viewportHeight: height).environmentObject(store).environmentObject(store.settings))
        popover.contentSize = NSSize(width: 400, height: height)
    }

    private func updateTitle() {
        guard let button = item.button, !popover.isShown else { return }
        let segments = store.menuBarSegments
        if segments.isEmpty {
            button.attributedTitle = NSAttributedString()
            lastTitle = NSAttributedString()
            item.length = NSStatusItem.squareLength
            button.image = whiteIcon
            button.contentTintColor = .white
            return
        }
        item.length = NSStatusItem.variableLength
        button.image = nil
        button.contentTintColor = nil
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let dotFont = NSFont.systemFont(ofSize: 8)
        for (i, seg) in segments.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            title.append(NSAttributedString(string: "●", attributes: [.font: dotFont, .foregroundColor: NSColor(seg.dot), .baselineOffset: 1.5]))
            title.append(NSAttributedString(string: " " + seg.text, attributes: [.font: font, .foregroundColor: NSColor(seg.color)]))
        }
        if !title.isEqual(to: lastTitle) {
            button.attributedTitle = title
            lastTitle = title
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        togglePopover()
    }

    func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            sizePopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        Task {
            await store.sleepControl.refresh()
            presentContextMenu()
        }
    }

    private func presentContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let dashboard = menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboard.target = self
        dashboard.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let awake = menu.addItem(withTitle: "Disable Sleep: \(store.sleepControl.stateLabel)", action: #selector(toggleSleep), keyEquivalent: "")
        awake.target = self
        awake.state = store.sleepControl.isSleepDisabled == true ? .on : .off
        awake.isEnabled = !store.sleepControl.isChanging
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func refreshNow() { Task { await store.refreshAll(force: true) } }
    @objc private func openDashboard() {
        popover.performClose(nil)
        DashboardWindowController.shared.show()
    }
    @objc private func openAnalysis() {
        popover.performClose(nil)
        DashboardWindowController.shared.show(tab: .analysis)
    }
    @objc private func openSettings() {
        popover.performClose(nil)
        DashboardWindowController.shared.show(tab: .settings)
    }
    @objc private func toggleSleep() { Task { await store.sleepControl.toggle() } }
}

extension Notification.Name {
    static let usageBarTogglePopover = Notification.Name("UsageBarTogglePopover")
    static let usageBarOpenDashboard = Notification.Name("UsageBarOpenDashboard")
    static let usageBarOpenSettings = Notification.Name("UsageBarOpenSettings")
    static let usageBarOpenAnalysis = Notification.Name("UsageBarOpenAnalysis")
}

@MainActor
enum MenuBarIcon {
    static func whiteLogo() -> NSImage {
        // Bake white into a non-template image so Aqua cannot recolor it black.
        // Simplify the app artwork to its bars and sparkle for an 18-point menu item.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.white.setFill()
            for bar in [NSRect(x: 2, y: 2, width: 4, height: 10),
                        NSRect(x: 7, y: 2, width: 4, height: 7),
                        NSRect(x: 12, y: 2, width: 4, height: 14)] {
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            }
            let sparkle = NSBezierPath()
            sparkle.move(to: NSPoint(x: 9, y: 15.5))
            sparkle.curve(to: NSPoint(x: 11, y: 13), controlPoint1: NSPoint(x: 9.4, y: 13.8), controlPoint2: NSPoint(x: 9.7, y: 13.4))
            sparkle.curve(to: NSPoint(x: 9, y: 10.5), controlPoint1: NSPoint(x: 9.7, y: 12.6), controlPoint2: NSPoint(x: 9.4, y: 12.2))
            sparkle.curve(to: NSPoint(x: 7, y: 13), controlPoint1: NSPoint(x: 8.6, y: 12.2), controlPoint2: NSPoint(x: 8.3, y: 12.6))
            sparkle.curve(to: NSPoint(x: 9, y: 15.5), controlPoint1: NSPoint(x: 8.3, y: 13.4), controlPoint2: NSPoint(x: 8.6, y: 13.8))
            sparkle.close()
            sparkle.fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "UsageBar"
        return image
    }
}

// MARK: - Dashboard window

@MainActor
final class DashboardWindowController {
    static let shared = DashboardWindowController()
    private var window: NSWindow?

    func show(tab: DashboardTab = .overview) {
        let store = UsageStore.shared
        store.dashboardTab = tab
        if window == nil {
            let host = NSHostingController(rootView: DashboardView().environmentObject(store).environmentObject(store.settings))
            let w = NSWindow(contentViewController: host)
            w.title = "UsageBar Dashboard"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Theme.bg)
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1060, height: 720))
            w.minSize = NSSize(width: 960, height: 600)
            w.center()
            w.setFrameAutosaveName("UsageBarDashboard")
            window = w
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.refreshLiveSessions()
        Task { await store.sleepControl.refresh() }
    }
}

/// Paints the popover chrome (including the arrow) in our background color.
struct PopoverChrome: NSViewRepresentable {
    var color: NSColor
    func makeNSView(context: Context) -> ChromeView { ChromeView(color: color) }
    func updateNSView(_ nsView: ChromeView, context: Context) { nsView.color = color; nsView.apply() }

    final class ChromeView: NSView {
        var color: NSColor
        init(color: NSColor) { self.color = color; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let frameView = window?.contentView?.superview else { return }
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = color.cgColor
        }
    }
}

// MARK: - CLI helpers

/// `UsageBar --render-preview out.png [--render-dashboard out2.png]` renders the UI with demo
/// data to PNG files and exits. Handy for checking the design without launching the menu bar app.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains(where: { $0.hasPrefix("--render-") }) else { return }
        RenderFlags.isRendering = true
        if let i = args.firstIndex(of: "--render-analysis"), i + 1 < args.count {
            func argument(_ name: String) -> String? {
                guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
                return args[index + 1]
            }
            let date = argument("--analysis-at").flatMap { Format.parseISO($0) } ?? Date()
            let days = min(120, max(1, argument("--analysis-days").flatMap(Int.init) ?? 7))
            let model = argument("--analysis-model")
            let height = min(6000, max(600, argument("--analysis-height").flatMap(Double.init) ?? 1100))
            if args.contains("--analysis-show-prices") { UsageAnalysisState.shared.previewShowPrices = true }
            if args.contains("--analysis-skeleton") {
                render(VStack(alignment: .leading, spacing: 0) { AnalysisSkeleton().padding(28) }
                    .background(Theme.bg).preferredColorScheme(.dark).frame(width: 1100, height: height), to: args[i + 1])
                exit(0)
            }
            let provider = model.flatMap { $0.split(separator: "/").first }.flatMap { ProviderID(rawValue: String($0)) }
            UsageAnalysisState.shared.loadLocalPreview(at: date)
            render(UsageAnalysisView(days: days, provider: provider, model: model,
                                     resolution: args.contains("--analysis-each-turn") ? .turns : .average)
                .frame(width: 1100, height: height), to: args[i + 1])
            exit(0)
        }
        let store = UsageStore.shared
        store.loadDemoData()
        store.settings.compactPopover = false
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            render(PopoverView().environmentObject(store).environmentObject(store.settings), to: args[i + 1])
        }
        if let i = args.firstIndex(of: "--render-compact"), i + 1 < args.count {
            store.settings.compactPopover = true
            render(PopoverView(viewportHeight: 560).environmentObject(store).environmentObject(store.settings), to: args[i + 1])
        }
        if let i = args.firstIndex(of: "--render-analysis-tab"), i + 1 < args.count {
            store.dashboardTab = .analysis
            UsageAnalysisState.shared.loadLocalPreview(at: Date())
            render(DashboardView().environmentObject(store).environmentObject(store.settings).frame(width: 980, height: 760), to: args[i + 1])
        }
        if let i = args.firstIndex(of: "--render-settings"), i + 1 < args.count {
            store.dashboardTab = .settings
            render(DashboardView().environmentObject(store).environmentObject(store.settings).frame(width: 980, height: 660), to: args[i + 1])
        }
        if let i = args.firstIndex(of: "--render-dashboard"), i + 1 < args.count {
            store.dashboardTab = .overview
            render(DashboardView().environmentObject(store).environmentObject(store.settings).frame(width: 980, height: 660), to: args[i + 1])
        }
        if let i = args.firstIndex(of: "--render-history"), i + 1 < args.count {
            store.dashboardTab = .history
            store.loadRealActivityForPreview()
            render(DashboardView().environmentObject(store).environmentObject(store.settings).frame(width: 980, height: 760), to: args[i + 1])
        }
        exit(0)
    }

    static func render<V: View>(_ view: V, to path: String) {
        // Native hosting also renders AppKit-backed controls and scroll views.
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { print("render failed: \(error)"); return }

        print("wrote \(path)")
    }
}

/// `UsageBar --probe` fetches every provider once, prints the result, and exits.
/// `UsageBar --reveal-sessions [n]` lists live sessions and where the terminal button would take you;
/// with an index it performs the reveal for that session and exits.
@MainActor
enum RevealProbe {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--reveal-sessions") else { return }
        if i + 1 < args.count, args[i + 1] == "test" {
            // Exercise the terminal-opening path with a session id that cannot exist.
            let fake = LiveSession(id: "/tmp/usagebar-probe-session.jsonl", provider: .claude, project: "tmp", cwd: "/tmp",
                                   model: nil, branch: nil, tokens: nil, tokensLabel: "ctx", lastActivity: Date(), isProcessRunning: false)
            print("resume command: \(SessionReveal.resumeCommand(fake) ?? "-")")
            SessionReveal.resumeInTerminal(fake)
            RunLoop.main.run(until: Date().addingTimeInterval(4))
            exit(0)
        }
        let sessions = LiveSessionScanner.scan()
        for (n, s) in sessions.enumerated() {
            print("[\(n)] \(s.provider.displayName) \(s.project) \(s.cwd)\n    → \(SessionReveal.describe(s))")
        }
        if i + 1 < args.count, let n = Int(args[i + 1]), sessions.indices.contains(n) {
            // Mirror the real app: the popover is active when the button is clicked, so activate ourselves first.
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            SessionReveal.reveal(sessions[n])
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            print("frontmost now: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        }
        exit(0)
    }
}

@MainActor
enum Probe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--probe") else { return }
        let skipActivity = CommandLine.arguments.contains("--no-activity")
        let providers: [any UsageProvider] = [
            ClaudeProvider(), CodexProvider(), CursorProvider(), GeminiProvider(), AntigravityProvider(), OpenCodeProvider(),
        ]
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            for p in providers {
                do {
                    let s = try await p.fetch()
                    print("✅ \(p.id.displayName)  plan=\(s.planName ?? "-")  account=\(s.accountLabel ?? "-")  note=\(s.note ?? "-")")
                    for w in s.windows {
                        let reset = w.resetsAt.map { Format.countdown(to: $0) ?? "" } ?? "-"
                        let proj = w.projectedPercent().map { Format.percent($0) } ?? "-"
                        print("     \(w.label.padding(toLength: 12, withPad: " ", startingAt: 0)) \(w.hasLimit ? Format.percent(w.percent) : "   ") resets \(reset)  pace \(proj)  \(w.detail ?? "")")
                    }
                    if let e = s.extraUsage { print("     \(e.title): \(e.detail)") }
                } catch let e as ProviderError {
                    print("⚠️  \(p.id.displayName)  [\(e.kind)] \(e.message)")
                } catch {
                    print("❌ \(p.id.displayName)  \(error)")
                }
            }
            let statuses = await StatusPageService.fetchAll(StatusService.allCases)
            for s in statuses { print("🌐 \(s.service.label): \(s.description)") }
            let t1 = Date()
            let live = LiveSessionScanner.scan()
            print("🟢 live sessions (\(String(format: "%.2f", Date().timeIntervalSince(t1)))s):")
            for s in live {
                print("     \(s.provider.displayName.padding(toLength: 9, withPad: " ", startingAt: 0)) \(s.project)  model=\(s.model ?? "-")  \(s.tokens.map { Format.tokens($0) } ?? "-") \(s.tokensLabel)  \(Format.relative(s.lastActivity))  running=\(s.isProcessRunning)  branch=\(s.branch ?? "-")")
            }
            if !skipActivity {
                let t0 = Date()
                let activity = ActivityScanner.scan()
                let byProvider = Dictionary(grouping: activity.days, by: \.provider).mapValues { $0.reduce(0) { $0 + $1.tokens } }
                print("📊 activity: \(activity.days.count) provider-days, tokens by provider: \(byProvider.map { "\($0.key.displayName)=\(Format.tokens($0.value))" }.sorted().joined(separator: ", "))  (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
            }
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
