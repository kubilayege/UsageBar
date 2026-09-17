import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppLogoView(size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("UsageBar").font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("AI usage at a glance").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section("Providers") {
                ForEach(ProviderID.allCases) { id in
                    Toggle(isOn: Binding(get: { settings.enabledProviders.contains(id) }, set: { _ in settings.toggle(id) })) {
                        HStack(spacing: 8) {
                            ProviderDot(id: id, size: 9)
                            Text(id.displayName)
                            if id.isExperimental { Badge(text: "experimental", color: Theme.textMuted) }
                        }
                    }
                }
            }
            Section("Refresh") {
                Picker("Interval", selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { Text(Format.interval($0)).tag($0) }
                }
                Text("Each provider also has a floor (Claude 2 min, Codex and Cursor 1 min). A 429 doubles the wait until a few refreshes succeed. The last good numbers are kept on disk across relaunches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Picker("Style", selection: $settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show pace indicator (↗ risky, ⚠︎ over)", isOn: $settings.showPaceInMenuBar)
            }
            Section("Notifications") {
                Toggle("Enable notifications", isOn: $settings.notificationsEnabled)
                Toggle("Crossing 75% / 90% / 100%", isOn: $settings.notifyThresholds).disabled(!settings.notificationsEnabled)
                Toggle("Window reset (usage available again)", isOn: $settings.notifyResets).disabled(!settings.notificationsEnabled)
                if !AppSettings.isBundled {
                    Text("Notifications are available in the packaged app.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Behavior") {
                SleepControlView()
                Toggle("Launch at login", isOn: $settings.launchAtLogin).disabled(!AppSettings.isBundled)
                Toggle("Compact popover", isOn: $settings.compactPopover)
                Toggle("Show live sessions", isOn: $settings.showLiveSessions)
                HStack {
                    Text("OpenCode daily token budget")
                    Spacer()
                    TextField("0 = none", value: $settings.opencodeDailyTokenBudget, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .multilineTextAlignment(.trailing)
                }
            }
            Section("Usage analysis") {
                Button("Analyze usage & effort…") {
                    NotificationCenter.default.post(name: .usageBarOpenAnalysis, object: nil)
                }
                Text("Compare models and reasoning effort over a custom time range, with token rates and monthly plan costs you can edit.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("View usage history…") { DashboardWindowController.shared.show() }
            }
            Section("Updates") {
                UpdateSettingsRows(updates: updates)
            }
            Section("Privacy") {
                Text("UsageBar reads the credentials your CLIs already store locally and talks only to each vendor's own usage endpoint, plus GitHub for the LiteLLM price list and update checks. History and activity caches live in ~/Library/Application Support/UsageBar. No telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .preferredColorScheme(.dark)
    }
}

struct UpdateSettingsRows: View {
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        HStack {
            Text("Installed version")
            Spacer()
            Text(UpdateChecker.currentVersion ?? "development build").foregroundStyle(.secondary).monospacedDigit()
        }
        Toggle("Check for updates daily", isOn: Binding(
            get: { updates.automaticallyChecksForUpdates },
            set: { updates.setAutomaticChecksEnabled($0) }
        )).disabled(!updates.isEnabled)
        HStack {
            Button(updates.isUpdateAvailable ? "Review Update…" : "Check for Updates…") { updates.check() }
                .disabled(!updates.canCheckForUpdates)
            Spacer()
            if let checked = updates.lastChecked {
                Text("Checked \(Format.relative(checked))").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let version = updates.availableVersion {
            Label("UsageBar \(version) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Theme.accent)
        } else if updates.phase == .noUpdate {
            Text("No updates available.").font(.caption).foregroundStyle(.secondary)
        }
        if case .failed(let message) = updates.phase {
            Text(message).font(.caption).foregroundStyle(Theme.caution)
        }
        Text("Download updates securely, then install and restart UsageBar when you’re ready.")
            .font(.caption).foregroundStyle(.secondary)
        if !AppSettings.isBundled {
            Text("Updates are available in the packaged app.").font(.caption).foregroundStyle(.secondary)
        }
        Link("Release notes", destination: UpdateChecker.releasesPage).font(.caption)
    }
}
