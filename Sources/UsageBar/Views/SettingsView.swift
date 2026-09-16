import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Form {
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
                    Text("Notifications need the .app bundle — run `make install`.").font(.caption).foregroundStyle(.secondary)
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
                UpdateSettingsRows(settings: settings, updates: updates)
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
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        HStack {
            Text("Installed version")
            Spacer()
            Text(UpdateChecker.currentVersion ?? "development build").foregroundStyle(.secondary).monospacedDigit()
        }
        Toggle("Check for updates daily", isOn: $settings.checkForUpdates)
        HStack {
            Button(updates.phase == .checking ? "Checking…" : "Check now") { Task { await updates.check() } }
                .disabled(updates.phase == .checking)
            Spacer()
            if let checked = updates.lastChecked {
                Text("Checked \(Format.relative(checked))").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let latest = updates.latest {
            if updates.isUpdateAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                        Text("UsageBar \(latest.version) is available").fontWeight(.semibold)
                        Spacer()
                        Link("Release notes", destination: latest.page).font(.caption)
                    }
                    if !latest.notes.isEmpty {
                        Text(latest.notes).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                    }
                    HStack(spacing: 10) {
                        switch updates.phase {
                        case .downloading(let fraction):
                            ProgressView(value: fraction).frame(width: 160)
                            Text("Downloading \(Int(fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                        case .verifying:
                            ProgressView().controlSize(.small)
                            Text("Verifying checksum…").font(.caption).foregroundStyle(.secondary)
                        case .opened(let file):
                            Button("Download again") { Task { await updates.downloadAndOpen() } }
                            Text("Opened \(file.lastPathComponent). Drag UsageBar to Applications, then relaunch.")
                                .font(.caption).foregroundStyle(.secondary)
                        default:
                            Button("Download and open…") { Task { await updates.downloadAndOpen() } }
                                .buttonStyle(.borderedProminent)
                            Text("Saves the DMG to Downloads, verifies its SHA-256 and mounts it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("You have the latest release (\(latest.version)).").font(.caption).foregroundStyle(.secondary)
            }
        } else if updates.lastChecked != nil, updates.phase != .checking {
            Text("No published release found yet.").font(.caption).foregroundStyle(.secondary)
        }
        if case .failed(let message) = updates.phase {
            Text(message).font(.caption).foregroundStyle(Theme.caution)
        }
        Text("Releases are built by the GitHub Actions workflow in this repository and downloaded from github.com/\(UpdateChecker.repository).")
            .font(.caption).foregroundStyle(.secondary)
    }
}
