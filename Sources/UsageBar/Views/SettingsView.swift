import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: UsageStore
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 26) {
                PageHeader(title: "Settings", subtitle: "What UsageBar tracks, where it shows it, and when it tells you.")

                SettingsSection("Providers") {
                    ForEach(ProviderID.allCases) { id in
                        SettingsRow(detail: id.howToConfigure.replacingOccurrences(of: "`", with: "")) {
                            HStack(spacing: 8) {
                                ProviderDot(id: id, size: 8)
                                Text(id.displayName)
                                if id.isExperimental { Badge(text: "experimental", color: Theme.textMuted) }
                            }
                        } control: {
                            Toggle("", isOn: Binding(get: { settings.enabledProviders.contains(id) }, set: { _ in settings.toggle(id) }))
                        }
                    }
                    if settings.enabledProviders.contains(.opencode) {
                        SettingsRow("OpenCode daily token budget", detail: "Shows OpenCode as a limit against this many tokens a day. Zero tracks usage without a limit.") {
                            TextField("0", value: $settings.opencodeDailyTokenBudget, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
                        }
                    }
                }

                if settings.enabledProviders.contains(.claude) || settings.enabledProviders.contains(.codex) {
                    SettingsSection("Accounts") { AccountRows() }
                }

                SettingsSection("Menu bar") {
                    SettingsRow("Style", detail: "Icon only keeps the menu bar quiet. The other styles show each provider's usage.") {
                        Picker("", selection: $settings.menuBarMode) {
                            ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 250)
                    }
                    SettingsRow("Show pace warnings", detail: "Adds ↗ when a limit is getting tight and ⚠︎ when it will run out before it resets.") {
                        Toggle("", isOn: $settings.showPaceInMenuBar)
                    }
                }

                SettingsSection("Popup") {
                    SettingsRow("Refresh every", detail: "Each provider also has a floor: Claude 2 min, Codex and Cursor 1 min. When a vendor rate-limits UsageBar, it waits longer and keeps the last good numbers on screen.") {
                        Picker("", selection: $settings.refreshInterval) {
                            ForEach(AppSettings.refreshChoices, id: \.self) { Text(Format.interval($0)).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 200)
                    }
                    SettingsRow("Compact view", detail: "Shorter popup without meter projections or service status.") {
                        Toggle("", isOn: $settings.compactPopover)
                    }
                    SettingsRow("Show live sessions", detail: "Agent sessions active in the last 10 minutes, with a button to jump to their terminal.") {
                        Toggle("", isOn: $settings.showLiveSessions)
                    }
                }

                SettingsSection("Notifications") {
                    SettingsRow("Notifications", detail: AppSettings.isBundled ? nil : "Available in the packaged app.") {
                        Toggle("", isOn: $settings.notificationsEnabled)
                    }
                    SettingsRow("When usage crosses 75%, 90% and 100%") {
                        Toggle("", isOn: $settings.notifyThresholds).disabled(!settings.notificationsEnabled)
                    }
                    SettingsRow("When a limit resets") {
                        Toggle("", isOn: $settings.notifyResets).disabled(!settings.notificationsEnabled)
                    }
                }

                SettingsSection("Sleep") {
                    SettingsRow("Disable sleep", detail: "Keeps the Mac awake with the lid closed, so long agent runs finish. Uses pmset; the setting stays after UsageBar quits.") {
                        SleepSwitch()
                    }
                    SleepAccessRows()
                }

                SettingsSection("General") {
                    SettingsRow("Launch at login", detail: AppSettings.isBundled ? nil : "Available in the packaged app.") {
                        Toggle("", isOn: $settings.launchAtLogin).disabled(!AppSettings.isBundled)
                    }
                    SettingsRow("Usage & effort analysis", detail: "Compare models and reasoning effort over a custom range, with token prices and plan costs you can edit.") {
                        Button("Open Analysis") { NotificationCenter.default.post(name: .usageBarOpenAnalysis, object: nil) }
                    }
                }

                SettingsSection("Updates") { UpdateSettingsRows(updates: updates) }

                SettingsSection("Privacy") {
                    Text("UsageBar reads the credentials your CLIs already store locally and talks only to each vendor's own usage endpoint, plus GitHub for the LiteLLM price list and update checks. History and activity caches live in ~/Library/Application Support/UsageBar. No telemetry.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .labelsHidden()
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

/// Every Claude and Codex account UsageBar tracks, with a name field, and the ways to add more.
private struct AccountRows: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: UsageStore

    private var providers: [ProviderID] { [.claude, .codex].filter { settings.enabledProviders.contains($0) } }

    var body: some View {
        ForEach(providers) { id in
            ForEach(store.accounts(for: id).filter { $0.key != nil || $0.email != nil }) { account in
                row(account)
            }
        }
        if settings.enabledProviders.contains(.codex) {
            SettingsRow("Remember Codex sign-ins", detail: "When codex login switches to another account, keep tracking the previous one until its token expires, usually about ten days later. UsageBar saves only the access token, readable by you alone, in ~/Library/Application Support/UsageBar.") {
                Toggle("", isOn: Binding(get: { settings.rememberCodexAccounts }, set: { on in
                    if !on { AccountDirectory.clearVault() }
                    settings.rememberCodexAccounts = on
                }))
            }
        }
        SettingsRow("Add an account folder", detail: "For accounts kept in their own folder with CLAUDE_CONFIG_DIR or CODEX_HOME. Folders in your home such as ~/.codex-work are found automatically.") {
            HStack(spacing: 8) {
                ForEach(providers) { id in
                    Button("\(id.displayName) Folder…") { addFolder(id) }
                }
            }
        }
    }

    private func row(_ account: Account) -> some View {
        SettingsRow(detail: detail(account)) {
            HStack(spacing: 8) {
                ProviderDot(id: account.provider, size: 8)
                Text(account.provider.displayName)
                Text(account.email ?? store.label(account)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                if account.source == .saved { Badge(text: "saved", color: Theme.textMuted) }
            }
        } control: {
            HStack(spacing: 8) {
                TextField("Name", text: Binding(
                    get: { settings.accountNicknames[account.id] ?? "" },
                    set: { settings.accountNicknames[account.id] = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder).frame(width: 130)
                .help("Shown instead of the email on cards, tabs and the menu bar")
                if account.source != .standard {
                    Button { remove(account) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help(account.source == .saved ? "Forget this saved sign-in" : "Stop tracking this folder")
                        .accessibilityLabel("Remove \(store.title(account))")
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
            }
        }
    }

    private func detail(_ a: Account) -> String {
        var parts = [a.sourceDescription]
        if let plan = store.snapshot(a)?.planName { parts.append(plan) }
        if a.source == .saved, let exp = a.codex?.expiresAt {
            parts.append(exp < store.now ? "sign-in expired \(Format.dateTime(exp))" : "sign-in valid until \(Format.dateTime(exp))")
        }
        return parts.joined(separator: " · ")
    }

    private func remove(_ a: Account) {
        switch a.source {
        case .standard: break
        case .saved: store.forgetSavedAccount(a)
        case .folder(let path):
            settings.accountNicknames[a.id] = nil
            if a.provider == .codex, let key = a.key { AccountDirectory.forget(key) }
            if a.provider == .claude { settings.claudeFolders.removeAll { $0 == path } }
            else { settings.codexFolders.removeAll { $0 == path } }
            settings.ignoredAccountFolders.insert(path)
        }
    }

    private func addFolder(_ id: ProviderID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: Files.home)
        panel.message = id == .claude ? "Choose the folder you use as CLAUDE_CONFIG_DIR." : "Choose the folder you use as CODEX_HOME."
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = AccountDirectory.normalize(url.path)
        settings.ignoredAccountFolders.remove(path)
        if id == .claude {
            if !settings.claudeFolders.contains(path) { settings.claudeFolders.append(path) }
        } else if !settings.codexFolders.contains(path) {
            settings.codexFolders.append(path)
        }
    }
}

/// The popup's sleep switch without its icon and label, for a Settings row.
private struct SleepSwitch: View {
    @ObservedObject private var control = SleepControl.shared
    var body: some View {
        HStack(spacing: 8) {
            if control.isChanging { ProgressView().controlSize(.small) }
            else if control.isSleepDisabled == nil { Text("Unknown").font(.system(size: 11.5)).foregroundStyle(Theme.textMuted) }
            Toggle("", isOn: Binding(get: { control.isSleepDisabled == true }, set: { _ in Task { await control.toggle() } }))
                .disabled(control.isChanging)
        }
        .task { if !RenderFlags.isRendering { await control.refresh() } }
    }
}

// MARK: - Building blocks

struct SettingsSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Legend(title).padding(.leading, 2)
            _VariadicView.Tree(DividedRows()) { content }
                .padding(.horizontal, 16)
                .panel()
        }
    }
}

/// Stacks rows with hairlines between them.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id { Rectangle().fill(Theme.line).frame(height: 1) }
                child
            }
        }
    }
}

struct SettingsRow<Title: View, Control: View>: View {
    var detail: String?
    @ViewBuilder var title: Title
    @ViewBuilder var control: Control

    init(detail: String? = nil, @ViewBuilder title: () -> Title, @ViewBuilder control: () -> Control) {
        self.detail = detail; self.title = title(); self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.vertical, 11)
    }
}

extension SettingsRow where Title == Text {
    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(detail: detail, title: { Text(title) }, control: control)
    }
}

struct UpdateSettingsRows: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        SettingsRow("Installed version", detail: statusLine) {
            HStack(spacing: 10) {
                Text(UpdateChecker.currentVersion ?? "development build").font(Theme.mono(12)).foregroundStyle(Theme.textSecondary)
                Button(updates.isUpdateAvailable ? "Review Update…" : "Check for Updates…") { updates.check() }
                    .disabled(!updates.canCheckForUpdates)
            }
        }
        SettingsRow("Check for updates daily", detail: "Updates download securely; UsageBar installs and restarts when you're ready.") {
            Toggle("", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticChecksEnabled($0) }
            )).disabled(!updates.isEnabled)
        }
        SettingsRow("Release notes") {
            Link("View on GitHub", destination: UpdateChecker.releasesPage).font(.system(size: 12)).foregroundStyle(Theme.accent)
        }
    }

    private var statusLine: String? {
        if let version = updates.availableVersion { return "UsageBar \(version) is available." }
        if case .failed(let message) = updates.phase { return message }
        if !AppSettings.isBundled { return "Updates are available in the packaged app." }
        var parts: [String] = []
        if updates.phase == .noUpdate { parts.append("You're up to date.") }
        if let checked = updates.lastChecked { parts.append("Checked \(Format.relative(checked)).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
