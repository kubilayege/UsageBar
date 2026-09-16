import SwiftUI
import Charts

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "History", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .history: return "chart.xyaxis.line"
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
            sidebar.frame(width: 210)
            Rectangle().fill(Theme.divider).frame(width: 1)
            Group {
                switch store.dashboardTab {
                case .overview: OverviewTab()
                case .history: HistoryTab()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .frame(minWidth: 860, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppLogoView(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UsageBar").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                    Text("Dashboard").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.bottom, 14)
            .padding(.top, 22)

            ForEach(DashboardTab.allCases) { t in
                Button { store.dashboardTab = t } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.icon).font(.system(size: 12)).frame(width: 16)
                        Text(t.rawValue).font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(store.dashboardTab == t ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(store.dashboardTab == t ? Theme.chipSelected : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("PROVIDERS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted).padding(.top, 16).padding(.leading, 10)
            ForEach(settings.orderedEnabledProviders) { id in
                HStack(spacing: 8) {
                    ProviderDot(id: id, size: 8)
                    Text(id.displayName).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let snap = store.snapshot(id) {
                        let limited = snap.windows.filter(\.hasLimit)
                        if !limited.isEmpty {
                            Circle().fill(snap.worstSeverity.color).frame(width: 7, height: 7)
                        }
                    } else if case .notConfigured = store.state(id) {
                        Image(systemName: "minus.circle").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    } else if store.state(id).errorMessage != nil {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.caution)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }

            Spacer()
            Button { Task { await store.refreshAll(force: true) } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
                    Text(store.isRefreshing ? "Refreshing…" : "Refresh all").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle())
            Text("Updated \(Format.relative(store.lastRefresh, now: store.now))")
                .font(.system(size: 10)).foregroundStyle(Theme.textMuted).padding(.leading, 2)
        }
        .padding(16)
    }
}

// MARK: - Overview

struct OverviewTab: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 16) {
                paceStrip
                let ids = settings.orderedEnabledProviders
                VStack(spacing: 14) {
                    ForEach(Array(stride(from: 0, to: ids.count, by: 2)), id: \.self) { i in
                        HStack(alignment: .top, spacing: 14) {
                            Card { ProviderCardView(id: ids[i], expanded: true) }.frame(maxWidth: .infinity)
                            if i + 1 < ids.count {
                                Card { ProviderCardView(id: ids[i + 1], expanded: true) }.frame(maxWidth: .infinity)
                            } else {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                liveSessions
                serviceHealth
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 20)
        }
    }

    private var paceStrip: some View {
        let items: [(ProviderID, UsageWindow, Double)] = settings.orderedEnabledProviders.compactMap { id in
            guard let w = store.snapshot(id)?.paceWindow, let proj = w.projectedPercent(now: store.now) else { return nil }
            return (id, w, proj)
        }
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Will you make it to the reset?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 10) {
                        ForEach(items, id: \.0) { id, w, proj in
                            let verdict = PaceVerdict.from(projected: proj)
                            Card(padding: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        ProviderDot(id: id, size: 8)
                                        Text("\(id.displayName) \(w.label)").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                                        Spacer()
                                        Badge(text: verdict.rawValue, color: verdict.color)
                                    }
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(Format.percent(proj)).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(verdict.color)
                                        Text("projected · \(Format.percent(w.percent)) now").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                                    }
                                    if let c = Format.countdown(to: w.resetsAt, from: store.now) {
                                        Text("resets in \(c)").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    private var liveSessions: some View {
        let sessions = store.liveSessions.filter { settings.enabledProviders.contains($0.provider) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Live sessions").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("agent sessions active in the last 10 minutes").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            if sessions.isEmpty {
                Text("None right now.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else {
                VStack(spacing: 6) { ForEach(sessions) { s in LiveSessionRow(session: s, now: store.now) } }
            }
        }
    }

    private var serviceHealth: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Service health").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 10) {
                ForEach(store.serviceStatuses) { s in
                    Button { NSWorkspace.shared.open(s.service.pageURL) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: s.isOperational ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(s.color)
                            Text(s.service.label).foregroundStyle(Theme.textSecondary)
                            Text(s.description).foregroundStyle(s.color).fontWeight(.semibold)
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                if store.serviceStatuses.isEmpty {
                    Text("Status pages not loaded yet.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                }
            }
        }
    }
}

// MARK: - History

struct HistoryTab: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    @State private var range: HistoryRange = .week
    @State private var provider: ProviderID = .claude
    @State private var activityProvider: ProviderID? = nil

    private var since: Date { store.now.addingTimeInterval(-range.seconds) }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Picker("", selection: $range) { ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                    Picker("", selection: $provider) {
                        ForEach(settings.orderedEnabledProviders) { Text($0.displayName).tag($0) }
                    }
                    .frame(width: 150)
                }
                trendSection
                statsSection
                heatmapSection
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 20)
        }
        .onAppear { if !settings.enabledProviders.contains(provider), let f = settings.orderedEnabledProviders.first { provider = f } }
    }

    // Trend of limit usage from the local history log.
    private var trendSection: some View {
        let points = store.history.series(provider: provider, since: since)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(provider.displayName) limit usage").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("last \(range.rawValue.lowercased())").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                if points.count < 2 {
                    Text("History builds up while UsageBar runs. Check back after a few refreshes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        .frame(height: 180).frame(maxWidth: .infinity)
                } else {
                    Chart(points) { p in
                        LineMark(x: .value("Time", p.t), y: .value("Used", p.pct))
                            .foregroundStyle(by: .value("Window", p.w))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        AreaMark(x: .value("Time", p.t), y: .value("Used", p.pct))
                            .foregroundStyle(by: .value("Window", p.w))
                            .opacity(0.08)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(Theme.divider)
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%").font(.system(size: 10)).foregroundStyle(Theme.textMuted) } }
                    } }
                    .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.divider); AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.textMuted) } }
                    .chartLegend(position: .top, alignment: .leading)
                    .frame(height: 200)
                }
            }
        }
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
                Text("Local activity").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("from Claude Code, Codex and OpenCode session logs").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Spacer()
                Picker("", selection: $activityProvider) {
                    Text("All").tag(ProviderID?.none)
                    ForEach([ProviderID.claude, .codex, .opencode]) { Text($0.displayName).tag(ProviderID?.some($0)) }
                }
                .frame(width: 130)
            }
            HStack(spacing: 10) {
                StatTile(value: Format.tokens(totalTokens), label: "tokens · last \(range.rawValue.lowercased())")
                StatTile(value: "\(totalMsgs)", label: "assistant turns")
                StatTile(value: "\(active.count)", label: "active days")
                StatTile(value: peak.map { Format.tokens($0.value) } ?? "—", label: peak.map { "peak · \($0.key.suffix(5))" } ?? "peak day", tint: Theme.accent)
                StatTile(value: Format.tokens(avg), label: "avg per active day")
            }
        }
    }

    private var heatmapSection: some View {
        var perDay: [String: Int] = [:]
        for d in store.activity?.days ?? [] where activityProvider == nil || d.provider == activityProvider {
            perDay[d.day, default: 0] += d.tokens
        }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Activity · last 16 weeks").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let at = store.activity?.scannedAt {
                        Text("scanned \(Format.relative(at, now: store.now))").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    } else {
                        Text("scanning logs…").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                }
                HeatmapView(values: perDay, color: activityProvider?.color ?? Theme.ok, weeks: 16, today: store.now)
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
    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    private var grid: [[Date]] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        let weekday = cal.component(.weekday, from: start) // 1 = Sunday
        let daysBackToMonday = (weekday + 5) % 7
        let thisMonday = start.addingTimeInterval(-Double(daysBackToMonday) * 86400)
        let firstMonday = thisMonday.addingTimeInterval(-Double(weeks - 1) * 7 * 86400)
        return (0..<weeks).map { w in (0..<7).map { d in firstMonday.addingTimeInterval(Double(w * 7 + d) * 86400) } }
    }

    private var thresholds: [Int] {
        let nonzero = values.values.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return [1, 2, 3, 4] }
        func q(_ f: Double) -> Int { nonzero[min(nonzero.count - 1, Int(Double(nonzero.count) * f))] }
        return [1, q(0.25), q(0.5), q(0.75)]
    }

    var body: some View {
        let g = grid
        let t = thresholds
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: gap) {
                VStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { d in
                        Text(d == 0 ? "Mon" : d == 2 ? "Wed" : d == 4 ? "Fri" : "")
                            .font(.system(size: 9)).foregroundStyle(Theme.textMuted)
                            .frame(width: 24, height: cell, alignment: .leading)
                    }
                }
                ForEach(0..<g.count, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            let date = g[w][d]
                            let key = Format.dayKey(date)
                            let v = values[key] ?? 0
                            let level = date > today ? -1 : (v <= 0 ? 0 : (v >= t[3] ? 4 : v >= t[2] ? 3 : v >= t[1] ? 2 : 1))
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(level < 0 ? Color.clear : level == 0 ? Color.white.opacity(0.06) : color.opacity(0.25 + 0.75 * Double(level) / 4))
                                .frame(width: cell, height: cell)
                                .help(level < 0 ? "" : "\(key): \(Format.tokens(v)) tokens")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Spacer()
                Text("less").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
                ForEach(0..<5, id: \.self) { l in
                    RoundedRectangle(cornerRadius: 2).fill(l == 0 ? Color.white.opacity(0.06) : color.opacity(0.25 + 0.75 * Double(l) / 4)).frame(width: 10, height: 10)
                }
                Text("more").font(.system(size: 9)).foregroundStyle(Theme.textMuted)
            }
        }
    }
}
