import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    var viewportHeight: CGFloat = 720

    private let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
            filterBar.padding(.horizontal, 18)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    cardsSection.padding(.top, 6)
                    Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 18)
                    if settings.showLiveSessions {
                        liveSessionsSection.padding(.horizontal, 18).padding(.top, 12)
                    }
                    if !settings.compactPopover {
                        statusSection.padding(.horizontal, 18).padding(.top, 12)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            SleepControlView().padding(.horizontal, 18).padding(.top, 10)
            footer.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
        }
        .frame(width: width, height: viewportHeight)
        .background(Theme.bg)
        .background(PopoverChrome(color: NSColor(Theme.bg)))
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AppLogoView(size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("UsageBar")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 6) {
                    Circle().fill(store.isRefreshing ? Theme.caution : Theme.ok).frame(width: 6, height: 6)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private var subtitle: String {
        let names = settings.orderedEnabledProviders.map(\.displayName)
        if names.isEmpty { return "No providers enabled" }
        if names.count <= 3 { return "Track " + names.joined(separator: ", ") }
        return "Track \(names.prefix(3).joined(separator: ", ")) & more"
    }

    // MARK: Filter

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 4) {
            filterChip(nil) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 12))
                    Text("All").font(.system(size: 13, weight: .semibold))
                }
            }
            ForEach(settings.orderedEnabledProviders) { id in
                filterChip(id) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            ProviderDot(id: id, size: 7)
                            Text(id.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                        }
                        Text(store.snapshot(id)?.primaryWindows.map(\.label).joined(separator: " · ") ?? id.windowSummary)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(4)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.chipFill))
        .frame(maxWidth: .infinity)
        .frame(height: 48)
    }

    private func filterChip<Label: View>(_ id: ProviderID?, @ViewBuilder label: () -> Label) -> some View {
        let selected = store.filter == id
        return Button {
            store.filter = id
        } label: {
            label()
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.chipSelected : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selected ? Theme.chipSelectedStroke : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Cards

    private var cardsSection: some View {
        let ids = store.visibleProviders
        return cards(ids)
    }

    private func cards(_ ids: [ProviderID]) -> some View {
        VStack(spacing: 0) {
            if ids.isEmpty {
                Text("Enable a provider in Settings to start tracking.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 24)
            }
            ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                ProviderCardView(id: id, compact: settings.compactPopover, expanded: store.filter != nil)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .contextMenu {
                        Button("Refresh \(id.displayName)") { Task { await store.refresh(id) } }
                        Button("Hide \(id.displayName)") { settings.toggle(id) }
                    }
                if i < ids.count - 1 {
                    Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 18)
                }
            }
        }
    }

    // MARK: Live sessions

    private var liveSessionsSection: some View {
        let sessions = Array(SelectionFilter.apply(
            to: store.liveSessions,
            enabled: settings.enabledProviders,
            selected: store.filter,
            id: \.provider
        ).prefix(5))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("LIVE SESSIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
                if !sessions.isEmpty {
                    Text("\(sessions.count)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Text("recent or running").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            }
            if sessions.isEmpty {
                Text(store.filter.map { "No \($0.displayName) sessions active right now." } ?? "No agent sessions active right now.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            ForEach(sessions) { s in LiveSessionRow(session: s, now: store.now) }
        }
    }

    // MARK: Status / Keep awake

    private var statusSection: some View {
        let statuses = store.serviceStatuses.filter { status in
            settings.orderedEnabledProviders.contains { $0.statusService == status.service }
                && (store.filter == nil || store.filter?.statusService == status.service)
        }
        return FlowLayout(spacing: 8) {
            ForEach(statuses) { s in
                Button { NSWorkspace.shared.open(s.service.pageURL) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: s.isOperational ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(s.color)
                        Text(s.service.label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Text(s.shortLabel).font(.system(size: 12, weight: .semibold)).foregroundStyle(s.color)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(ChipButtonStyle())
                .help(s.description)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            utilityActions
            navigationActions
        }
    }

    private var utilityActions: some View {
        HStack(spacing: 8) {
            Button { Task { await store.refreshAll(force: true) } } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(store.isRefreshing ? 0.4 : 1)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(ChipButtonStyle())
            .help("Refresh now. Last: \(Format.relative(store.lastRefresh, now: store.now))")

            Menu {
                ForEach(AppSettings.refreshChoices, id: \.self) { s in
                    Button { settings.refreshInterval = s } label: {
                        HStack { Text("Every \(Format.interval(s))"); if s == settings.refreshInterval { Image(systemName: "checkmark") } }
                    }
                }
                Divider()
                Text("Claude is polled at most every 2 min").font(.caption)
            } label: {
                Text(Format.interval(settings.refreshInterval)).font(Theme.smallNumberFont).foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chipFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
            .help("Refresh interval")

            Button { settings.compactPopover.toggle() } label: {
                Image(systemName: settings.compactPopover ? "arrow.up.and.down" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(ChipButtonStyle())
            .help(settings.compactPopover ? "Show details" : "Compact view")

            Button { NotificationCenter.default.post(name: .usageBarOpenAnalysis, object: nil) } label: {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(ChipButtonStyle())
            .help("Analyze usage, reasoning effort and cost per turn")

            Spacer(minLength: 0)

            if let version = updates.availableVersion {
                Button { updates.check() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 12))
                        Text("Update \(version)").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(!updates.canCheckForUpdates)
                .help("Review and install UsageBar \(version).")
            }
        }
    }

    private var navigationActions: some View {
        HStack(spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .usageBarOpenDashboard, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.system(size: 13))
                    Text("Dashboard").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 22)
            }
            .buttonStyle(ChipButtonStyle(selected: true))
            .help("Open the dashboard overview")

            Button {
                NotificationCenter.default.post(name: .usageBarOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel("Settings")
            .help("Open Settings in the dashboard")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(ChipButtonStyle())
            .accessibilityLabel("Quit UsageBar")
            .help("Quit UsageBar")
        }
    }
}
