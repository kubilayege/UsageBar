import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var workLog = WorkLogState.shared
    var viewportHeight: CGFloat = 720
    @State var showingReceipt = false
    @State private var receiptRange: QuickRange = .today

    private let width: CGFloat = 400
    private let inset: CGFloat = 16

    var body: some View {
        Group {
            if showingReceipt { receiptPage } else { usagePage }
        }
        .frame(width: width, height: viewportHeight)
        .background(Theme.bg)
        .background(PopoverChrome(color: NSColor(Theme.bg)))
        .preferredColorScheme(.dark)
    }

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, inset).padding(.top, 13).padding(.bottom, 12)
            runway
            tabs.padding(.horizontal, inset - 4).padding(.top, 10).padding(.bottom, 4)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    cards
                    if !settings.compactPopover && !store.visibleAccounts.isEmpty {
                        MeterKey().padding(.horizontal, inset).padding(.top, 2).padding(.bottom, 12)
                    }
                    if settings.showLiveSessions { liveSessions.padding(.horizontal, inset).padding(.top, 12) }
                    if !settings.compactPopover { statusSection.padding(.horizontal, inset).padding(.top, 14) }
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            footer.padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 14)
                .background(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    // MARK: Receipt page

    enum QuickRange: String, CaseIterable, Identifiable {
        case today = "Today", yesterday = "Yesterday", week = "This week"
        var id: String { rawValue }
        var range: WorkRange {
            switch self {
            case .today: return .today()
            case .yesterday: return WorkRange.today().shifted(by: -1)
            case .week: return .today(.week)
            }
        }
    }

    private var receiptPage: some View {
        let receipt = workLog.receipt(receiptRange.range)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { withAnimation(.snappy(duration: 0.2)) { showingReceipt = false } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Usage").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back to usage (Esc)")
                Spacer()
                Text("Work receipt").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { NotificationCenter.default.post(name: .usageBarOpenWorkLog, object: nil) } label: {
                    HStack(spacing: 3) {
                        Text("Work Log").font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Open the full Work Log with projects, files and every session")
            }
            .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 10)

            HStack(spacing: 2) {
                ForEach(QuickRange.allCases) { r in
                    let selected = receiptRange == r
                    Button { receiptRange = r } label: {
                        Text(r.rawValue).font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.chipSelected : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chipFill))
            .padding(.horizontal, inset)

            if let receipt {
                Text(receipt.isEmpty ? "No agent activity \(receiptRange == .week ? "this week" : receiptRange.rawValue.lowercased()) yet."
                     : "\(Format.hm(receipt.activeMinutes)) active · \(WorkReceiptExport.count(receipt.projects.count, "project")) · \(WorkReceiptExport.count(receipt.sessionCount, "session"))")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 8)
                ReceiptPreview(receipt: receipt, maxPaperHeight: viewportHeight - 250)
                    .padding(.horizontal, inset).padding(.bottom, 14)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading local agent logs…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { workLog.scan(ifOlderThan: 60) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            AppLogoView(size: 22)
            Text("UsageBar").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if let version = updates.availableVersion ?? (RenderFlags.isRendering ? "preview" : nil) {
                Button { updates.check() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 10.5))
                        Text("Update ready").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.onBone)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(!updates.canCheckForUpdates && !RenderFlags.isRendering)
                .help("UsageBar \(version) is ready. Review and install it.")
            }
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Text("Updated \(Format.relative(store.lastRefresh, now: store.now))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .help("Refreshes every \(Format.interval(settings.refreshInterval))")
            }
        }
    }

    // MARK: Runway

    @ViewBuilder private var runway: some View {
        let r = Runway(sources: store.runwaySources(store.visibleAccounts), now: store.now)
        if r.lead != nil {
            RunwayView(runway: r, now: store.now, size: settings.compactPopover ? .compact : .popover)
                .padding(.horizontal, 14).padding(.vertical, settings.compactPopover ? 9 : 13)
                .panel(radius: 11)
                .padding(.horizontal, inset - 4)
        }
    }

    // MARK: Tabs

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tab(nil, "All")
                ForEach(settings.orderedEnabledProviders) { tab($0, $0.displayName) }
            }
        }
        .frame(height: 30)
    }

    private func tab(_ id: ProviderID?, _ title: String) -> some View {
        let selected = store.filter == id
        let status = id.flatMap { ProviderStatus.worst(store.snapshots($0), now: store.now) }
        return Button { store.filter = id } label: {
            HStack(spacing: 5) {
                if let status { Circle().fill(status.color).frame(width: 5, height: 5) }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.chipSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(id.map { p in status.map { "\(p.displayName): \($0.text)" } ?? p.displayName } ?? "All providers")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Cards

    private var cards: some View {
        let accounts = store.visibleAccounts
        return VStack(spacing: 0) {
            if accounts.isEmpty {
                Text("Turn on a provider in Settings to start tracking.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { i, account in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, inset) }
                ProviderCardView(account: account, compact: settings.compactPopover, expanded: false)
                    .padding(.horizontal, inset)
                    .padding(.vertical, settings.compactPopover ? 9 : 12)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Refresh \(store.title(account))") { Task { await store.refresh(account) } }
                        Button("Hide \(account.provider.displayName)") { settings.toggle(account.provider) }
                    }
            }
        }
    }

    // MARK: Live sessions

    private var liveSessions: some View {
        let sessions = Array(SelectionFilter.apply(
            to: store.liveSessions,
            enabled: settings.enabledProviders,
            selected: store.filter,
            id: \.provider
        ).prefix(5))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Legend("Live sessions")
                if !sessions.isEmpty { Text("\(sessions.count)").font(Theme.legend).foregroundStyle(Theme.textMuted) }
            }
            .padding(.bottom, 2)
            if sessions.isEmpty {
                Text(store.filter.map { "No \($0.displayName) sessions in the last 10 minutes." } ?? "No agent sessions in the last 10 minutes.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            }
            ForEach(sessions) { LiveSessionRow(session: $0, now: store.now) }
        }
    }

    // MARK: Service status

    private var statusSection: some View {
        let statuses = store.serviceStatuses.filter { status in
            settings.orderedEnabledProviders.contains { $0.statusService == status.service }
                && (store.filter == nil || store.filter?.statusService == status.service)
        }
        return Group {
            if !statuses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Legend("Service status")
                    FlowLayout(spacing: 12) {
                        ForEach(statuses) { s in
                            Button { NSWorkspace.shared.open(s.service.pageURL) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(s.color).frame(width: 5, height: 5)
                                    Text(s.service.label).foregroundStyle(Theme.textSecondary)
                                    if !s.isOperational { Text(s.shortLabel).foregroundStyle(s.color).fontWeight(.semibold) }
                                }
                                .font(.system(size: 11.5))
                                .lineLimit(1).fixedSize()
                            }
                            .buttonStyle(.plain)
                            .help("\(s.description). Open the status page.")
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                SleepControlView()
                Spacer(minLength: 4)
                workLogButtons
            }
            HStack(spacing: 6) {
                Button {
                    NotificationCenter.default.post(name: .usageBarOpenDashboard, object: nil)
                } label: {
                    HStack(spacing: 6) {
                        Text("Open dashboard").font(.system(size: 12.5, weight: .semibold))
                        Spacer(minLength: 4)
                        Text("⇧⌘D").font(.system(size: 11, weight: .medium)).opacity(0.55)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle(prominent: true))
                .help("Overview, work log, history, analysis and settings")

                Button { Task { await store.refreshAll(force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .opacity(store.isRefreshing ? 0.4 : 1)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(ChipButtonStyle())
                .help("Refresh now")
                .accessibilityLabel("Refresh now")

                moreMenu
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Menu("Refresh every \(Format.interval(settings.refreshInterval))") {
                ForEach(AppSettings.refreshChoices, id: \.self) { s in
                    Toggle(Format.interval(s), isOn: Binding(get: { settings.refreshInterval == s }, set: { if $0 { settings.refreshInterval = s } }))
                }
                Divider()
                Text("Claude is polled at most every 2 minutes")
            }
            Toggle("Compact view", isOn: $settings.compactPopover)
            Toggle("Show live sessions", isOn: $settings.showLiveSessions)
            Divider()
            Button(updates.isUpdateAvailable ? "Review Update…" : "Check for Updates…") { updates.check() }
                .disabled(!updates.canCheckForUpdates)
            Button("Settings…") { NotificationCenter.default.post(name: .usageBarOpenSettings, object: nil) }
            Divider()
            Button("Quit UsageBar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 38, height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
        .help("Refresh interval, view options, updates and quit")
        .accessibilityLabel("More")
    }

    /// Today's work receipt: open it in the dashboard, or copy it straight away.
    private var workLogButtons: some View {
        let today = workLog.receipt(.today(), priced: false)
        let copied = workLog.copiedID == "today"
        return HStack(spacing: 1) {
            Button {
                receiptRange = .today
                withAnimation(.snappy(duration: 0.2)) { showingReceipt = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "receipt").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    Text("Today").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Text(today.map { Format.hm($0.activeMinutes) } ?? "…").font(Theme.readout(14)).foregroundStyle(Theme.textPrimary)
                }
                .fixedSize()
                .padding(.horizontal, 10).frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(today.map { "Show today's receipt: " + WorkReceiptExport.summary($0, workLog.options) } ?? "Show today's receipt")

            Rectangle().fill(Theme.line).frame(width: 1, height: 16)

            Button { workLog.copyToday() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? Theme.ok : Theme.textSecondary)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy today's work receipt")
            .help("Copy today's work receipt as \(settings.workCopyFormat.rawValue.lowercased())")
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
    }
}
