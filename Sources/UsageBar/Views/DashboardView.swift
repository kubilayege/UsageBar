import SwiftUI
import Charts

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview", workLog = "Work Log", history = "History", analysis = "Analysis", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .workLog: return "receipt"
        case .history: return "chart.xyaxis.line"
        case .analysis: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .day: return 86400
        case .week: return 7 * 86400
        case .month: return 30 * 86400
        }
    }
    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 204).background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch store.dashboardTab {
                case .overview: OverviewTab()
                case .workLog: WorkLogView()
                case .history: HistoryTab()
                case .analysis: UsageAnalysisView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 960, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                AppLogoView(size: 26)
                Text("UsageBar").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, 6)
            .padding(.top, 40)
            .padding(.bottom, 18)

            ForEach(DashboardTab.allCases) { t in
                let selected = store.dashboardTab == t
                Button { store.dashboardTab = t } label: {
                    HStack(spacing: 9) {
                        Image(systemName: t.icon).font(.system(size: 12)).frame(width: 16)
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textMuted)
                        Text(t.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.chipSelected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            Legend("Providers").padding(.top, 22).padding(.bottom, 6).padding(.leading, 8)
            ForEach(store.enabledAccounts) { account in
                let status = providerStatus(account)
                HStack(spacing: 8) {
                    ProviderDot(id: account.provider, size: 6)
                    Text(store.title(account)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status.text).font(.system(size: 11, weight: .medium)).foregroundStyle(status.color).lineLimit(1)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .contentShape(Rectangle())
                .onTapGesture { store.dashboardTab = .overview }
            }

            Spacer()
            Button { Task { await store.refreshAll(force: true) } } label: {
                HStack(spacing: 6) {
                    if store.isRefreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                    Text(store.isRefreshing ? "Refreshing…" : "Refresh all").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(store.isRefreshing)
            Text("Updated \(Format.relative(store.lastRefresh, now: store.now))")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity).padding(.top, 4)
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
    }

    private func providerStatus(_ account: Account) -> (text: String, color: Color) {
        let state = store.state(account)
        if let snap = state.snapshot { return ProviderStatus.of(snap, now: store.now) }
        if case .notConfigured = state { return ("Not set up", Theme.textMuted) }
        if state.errorMessage != nil { return ("Error", Theme.caution) }
        return ("…", Theme.textMuted)
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Overview",
                           subtitle: "Updated \(Format.relative(store.lastRefresh, now: store.now)) · refreshes every \(Format.interval(settings.refreshInterval))")
                runway
                providerGrid
                HStack(alignment: .top, spacing: 14) {
                    liveSessions.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16).panel()
                    serviceHealth.frame(width: 260).frame(maxHeight: .infinity, alignment: .topLeading).padding(16).panel()
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
        }
    }

    @ViewBuilder private var runway: some View {
        let r = Runway(sources: store.runwaySources(store.enabledAccounts), now: store.now)
        if r.lead != nil {
            RunwayView(runway: r, now: store.now, size: .dashboard)
                .padding(.horizontal, 22).padding(.vertical, 20)
                .panel(radius: 12)
        }
    }

    private var providerGrid: some View {
        let accounts = store.enabledAccounts
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(stride(from: 0, to: accounts.count, by: 2)), id: \.self) { i in
                HStack(alignment: .top, spacing: 14) {
                    providerPanel(accounts[i])
                    if i + 1 < accounts.count { providerPanel(accounts[i + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !accounts.isEmpty { MeterKey().padding(.leading, 2) }
        }
    }

    private func providerPanel(_ account: Account) -> some View {
        ProviderCardView(account: account, expanded: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)
            .panel()
            .contextMenu {
                Button("Refresh \(store.title(account))") { Task { await store.refresh(account) } }
            }
    }

    private var liveSessions: some View {
        let sessions = store.liveSessions.filter { settings.enabledProviders.contains($0.provider) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Legend("Live sessions")
                Spacer()
                Text("active in the last 10 minutes").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            .padding(.bottom, 2)
            if sessions.isEmpty {
                Text("No agent sessions right now. They appear here as Claude Code, Codex or OpenCode write to their logs.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                    LiveSessionRow(session: s, now: store.now)
                }
            }
        }
    }

    private var serviceHealth: some View {
        VStack(alignment: .leading, spacing: 8) {
            Legend("Service status").padding(.bottom, 2)
            if store.serviceStatuses.isEmpty {
                Text("Status pages haven't loaded yet.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            ForEach(store.serviceStatuses) { s in
                Button { NSWorkspace.shared.open(s.service.pageURL) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(s.color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.service.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            Text(s.description).font(.system(size: 11)).foregroundStyle(s.isOperational ? Theme.textMuted : s.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the \(s.service.label) status page")
            }
        }
    }
}

// MARK: - History

struct HistoryTab: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    @State private var range: HistoryRange = .week
    /// An `Account.id`.
    @State private var accountID: String = ProviderID.claude.rawValue
    @State private var activityProvider: ProviderID? = nil

    private var account: Account {
        store.enabledAccounts.first { $0.id == accountID } ?? store.enabledAccounts.first ?? Account(provider: .claude, key: nil, source: .standard)
    }
    private var provider: ProviderID { account.provider }

    private var since: Date { store.now.addingTimeInterval(-range.seconds) }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "History", subtitle: "Limits recorded while UsageBar runs, and activity from local session logs.") {
                    Picker("", selection: $range) { ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                }
                trendSection
                statsSection
                heatmapSection
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
        }
        .onAppear { if !store.enabledAccounts.contains(where: { $0.id == accountID }), let f = store.enabledAccounts.first { accountID = f.id } }
    }

    // Trend of limit usage from the local history log.
    private var trendSection: some View {
        // Points from before accounts existed belong to the provider's first account.
        let points = store.history.series(provider: provider, account: account.key,
                                          includeUnkeyed: store.accounts(for: provider).first == account, since: since)
        let windows = Array(NSOrderedSet(array: points.map(\.w))) as? [String] ?? []
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Legend("Limit usage")
                    Spacer()
                    ForEach(Array(windows.enumerated()), id: \.element) { i, w in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1).fill(Self.windowColor(i, provider)).frame(width: 10, height: 3)
                            Text(w).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Picker("", selection: $accountID) {
                        ForEach(store.enabledAccounts) { Text(store.title($0)).tag($0.id) }
                    }
                    .labelsHidden().frame(width: store.enabledAccounts.count > settings.enabledProviders.count ? 210 : 130)
                }
                if points.count < 2 {
                    Text("History builds up while UsageBar runs. Check back after a few refreshes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        .frame(height: 200).frame(maxWidth: .infinity)
                } else {
                    Chart(points) { p in
                        LineMark(x: .value("Time", p.t), y: .value("Used", min(100, p.pct)))
                            .foregroundStyle(by: .value("Window", p.w))
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 1.75))
                    }
                    .chartForegroundStyleScale(domain: windows, range: windows.indices.map { Self.windowColor($0, provider) })
                    .chartLegend(.hidden)
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(v.as(Double.self) == 100 ? Theme.critical.opacity(0.35) : Theme.line)
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textMuted) } }
                    } }
                    .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.textMuted) } }
                    .chartPlotStyle { $0.clipped() }
                    .frame(height: 220)
                }
            }
        }
    }

    static func windowColor(_ index: Int, _ provider: ProviderID) -> Color {
        [Theme.textPrimary, provider.color, Theme.caution, Theme.textSecondary][index % 4]
    }

    private var rangeDays: [DayActivity] {
        guard let a = store.activity else { return [] }
        let start = Format.dayKey(Calendar.current.startOfDay(for: store.now).addingTimeInterval(-Double(range.days - 1) * 86400))
        return a.days.filter { $0.day >= start && (activityProvider == nil || $0.provider == activityProvider) }
    }

    private var statsSection: some View {
        let days = rangeDays
        let totalTokens = days.reduce(0) { $0 + $1.tokens }
        let totalMsgs = days.reduce(0) { $0 + $1.messages }
        var perDay: [String: Int] = [:]
        for d in days { perDay[d.day, default: 0] += d.tokens }
        let active = perDay.filter { $0.value > 0 }
        let peak = active.max { $0.value < $1.value }
        let avg = active.isEmpty ? 0 : totalTokens / active.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Legend("Local activity")
                Text("from Claude Code, Codex and OpenCode logs").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Spacer()
                Picker("", selection: $activityProvider) {
                    Text("All agents").tag(ProviderID?.none)
                    ForEach([ProviderID.claude, .codex, .opencode]) { Text($0.displayName).tag(ProviderID?.some($0)) }
                }
                .labelsHidden().frame(width: 130)
            }
            ReadoutStrip(items: [
                .init(value: Format.tokens(totalTokens), label: "tokens, last \(range.rawValue.lowercased())"),
                .init(value: totalMsgs.formatted(), label: "assistant turns"),
                .init(value: "\(active.count)", label: active.count == 1 ? "active day" : "active days"),
                .init(value: peak.map { Format.tokens($0.value) } ?? "—", label: peak.map { "peak, \(Self.dayLabel($0.key))" } ?? "peak day"),
                .init(value: Format.tokens(avg), label: "per active day"),
            ])
        }
    }

    static func dayLabel(_ key: String) -> String {
        Format.day(from: key).map { WorkRange.format("EEE d MMM", $0) } ?? key
    }

    private var heatmapSection: some View {
        var perDay: [String: Int] = [:]
        for d in store.activity?.days ?? [] where activityProvider == nil || d.provider == activityProvider {
            perDay[d.day, default: 0] += d.tokens
        }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Legend("Tokens per day · last 17 weeks")
                    Spacer()
                    Text(store.activity.map { "Scanned \(Format.relative($0.scannedAt, now: store.now))" } ?? "Reading logs…")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                HStack(alignment: .top, spacing: 36) {
                    HeatmapView(values: perDay, color: activityProvider?.color ?? Theme.textPrimary, weeks: 17, today: store.now)
                    WeekdayProfile(values: perDay, color: activityProvider?.color ?? Theme.textPrimary)
                }
            }
        }
    }
}

// MARK: - Heatmap

struct HeatmapView: View {
    var values: [String: Int]
    var color: Color
    var weeks: Int
    var today: Date
    private let cell: CGFloat = 16
    private let gap: CGFloat = 3

    private var grid: [[Date]] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        let weekday = cal.component(.weekday, from: start) // 1 = Sunday
        let daysBackToMonday = (weekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -daysBackToMonday, to: start) ?? start
        return (0..<weeks).map { w in
            (0..<7).map { d in cal.date(byAdding: .day, value: (w - weeks + 1) * 7 + d, to: thisMonday) ?? thisMonday }
        }
    }

    private var thresholds: [Int] {
        let nonzero = values.values.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return [1, 2, 3, 4] }
        func q(_ f: Double) -> Int { nonzero[min(nonzero.count - 1, Int(Double(nonzero.count) * f))] }
        return [1, q(0.25), q(0.5), q(0.75)]
    }

    private func fill(_ level: Int) -> Color {
        level < 0 ? .clear : level == 0 ? Color.white.opacity(0.05) : color.opacity(0.18 + 0.82 * Double(level) / 4)
    }

    var body: some View {
        let g = grid
        let t = thresholds
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    Color.clear.frame(width: 26, height: 12)
                    ForEach(0..<7, id: \.self) { d in
                        Text(d == 0 ? "Mon" : d == 2 ? "Wed" : d == 4 ? "Fri" : "")
                            .font(.system(size: 9)).foregroundStyle(Theme.textMuted)
                            .frame(width: 26, height: cell, alignment: .leading)
                    }
                }
                ForEach(0..<g.count, id: \.self) { w in
                    VStack(spacing: gap) {
                        Text(monthLabel(g, w)).font(.system(size: 9)).foregroundStyle(Theme.textMuted)
                            .fixedSize().frame(width: cell, height: 12, alignment: .leading)
                        ForEach(0..<7, id: \.self) { d in
                            let date = g[w][d]
                            let key = Format.dayKey(date)
                            let v = values[key] ?? 0
                            let level = date > today ? -1 : (v <= 0 ? 0 : (v >= t[3] ? 4 : v >= t[2] ? 3 : v >= t[1] ? 2 : 1))
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(fill(level))
                                .frame(width: cell, height: cell)
                                .help(level < 0 ? "" : "\(HistoryTab.dayLabel(key)): \(Format.tokens(v)) tokens")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.system(size: 9.5)).foregroundStyle(Theme.textMuted)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2).fill(fill(l)).frame(width: 10, height: 10)
                }
                Text("More").font(.system(size: 9.5)).foregroundStyle(Theme.textMuted)
            }
            .padding(.leading, 26 + gap)
        }
    }

    /// Month name above the first week that starts in it.
    private func monthLabel(_ g: [[Date]], _ w: Int) -> String {
        let cal = Calendar.current
        let month = cal.component(.month, from: g[w][0])
        if w > 0 && cal.component(.month, from: g[w - 1][0]) == month { return "" }
        return w == 0 ? "" : WorkRange.format("MMM", g[w][0])
    }
}

/// Average tokens on each weekday across the heatmap's days, busiest first to read at a glance.
struct WeekdayProfile: View {
    var values: [String: Int]
    var color: Color

    private var averages: [(name: String, value: Double)] {
        var sum = [Int](repeating: 0, count: 7), count = [Int](repeating: 0, count: 7)
        let cal = Calendar.current
        for (key, v) in values {
            guard let date = Format.day(from: key) else { continue }
            let i = (cal.component(.weekday, from: date) + 5) % 7 // Monday = 0
            sum[i] += v; count[i] += 1
        }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return (0..<7).map { (names[$0], count[$0] > 0 ? Double(sum[$0]) / Double(count[$0]) : 0) }
    }

    var body: some View {
        let rows = averages
        let top = rows.map(\.value).max() ?? 0
        VStack(alignment: .leading, spacing: 7) {
            Text("Average on active days").font(.system(size: 11)).foregroundStyle(Theme.textMuted).padding(.bottom, 2)
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 10) {
                    Text(row.name).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 28, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                            RoundedRectangle(cornerRadius: 2).fill(color.opacity(row.value == top && top > 0 ? 0.95 : 0.55))
                                .frame(width: top > 0 ? geo.size.width * row.value / top : 0)
                        }
                    }
                    .frame(height: 8)
                    Text(row.value > 0 ? Format.tokens(Int(row.value)) : "—").font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary).frame(width: 48, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
