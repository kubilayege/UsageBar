import SwiftUI

/// One provider block: header row, one row per window, optional pace and overage rows.
struct ProviderCardView: View {
    @EnvironmentObject var store: UsageStore
    var id: ProviderID
    var compact = false
    var expanded = false

    private var state: ProviderState { store.state(id) }
    private var snapshot: UsageSnapshot? { state.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let snap = snapshot {
                ForEach(snap.primaryWindows) { w in row(w) }
                if expanded { ForEach(snap.secondaryWindows) { w in row(w) } }
                if !compact, let pace = snap.paceWindow {
                    if let projected = pace.projectedPercent(now: store.now) {
                        paceRow(projected, window: pace)
                    } else if expanded {
                        message("Pace: too early in the \(pace.label) window to project.", icon: "clock", color: Theme.textMuted)
                    }
                }
                if let extra = snap.extraUsage { extraRow(extra) }
                if let resets = snap.bankedResets {
                    HStack {
                        Label("Banked resets", systemImage: "arrow.counterclockwise")
                        Spacer()
                        Text("\(resets.available)").monospacedDigit().fontWeight(.semibold)
                        if let applicable = resets.applicable {
                            Text("· \(applicable) applicable now").foregroundStyle(Theme.textMuted)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .help("Reset credits reported by Codex. Applicable counts depend on the current limit. No resets are used by UsageBar.")
                }
                if expanded { footer(snap) }
            }
            if let msg = state.errorMessage {
                message(msg, icon: "exclamationmark.triangle.fill", color: Theme.caution)
            } else if case .cooldown(let until, let stale) = state, expanded || stale == nil {
                message("Rate-limited by the API · retrying in \(Format.countdown(to: until, from: store.now) ?? "a moment")", icon: "clock", color: Theme.textMuted)
            } else if case .notConfigured(let msg) = state {
                message(msg, icon: "person.crop.circle.badge.questionmark", color: Theme.textMuted)
            } else if case .loading(nil) = state {
                message("Loading…", icon: "hourglass", color: Theme.textMuted)
            } else if case .idle = state {
                message("Waiting for first refresh…", icon: "hourglass", color: Theme.textMuted)
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            ProviderDot(id: id)
            Text(id.displayName)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if id.isExperimental { Badge(text: "beta", color: Theme.textMuted) }
            Spacer()
            if state.isLoading {
                ProgressView().controlSize(.mini)
            }
            if let snap = snapshot {
                let limited = snap.windows.filter(\.hasLimit)
                Text(limited.isEmpty ? (expanded ? "Tracking" : (snap.planName.map { "\($0) plan" } ?? "Tracking")) : snap.worstSeverity.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(limited.isEmpty ? Theme.textSecondary : snap.worstSeverity.color)
            }
        }
    }

    private var headerSubtitle: String {
        guard let snap = snapshot else { return id.windowSummary }
        if expanded, let plan = snap.planName { return plan }
        let labels = snap.primaryWindows.map(\.label)
        return labels.isEmpty ? id.windowSummary : labels.joined(separator: " · ")
    }

    private func row(_ w: UsageWindow) -> some View {
        HStack(spacing: 10) {
            Text(w.label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
            if w.hasLimit {
                UsageBarView(percent: w.percent, color: w.severity.color)
                Text(Format.percent(w.percent))
                    .font(Theme.numberFont)
                    .foregroundStyle(w.severity.color)
                    .frame(width: 48, alignment: .trailing)
            } else {
                Text(w.detail ?? "—")
                    .font(Theme.smallNumberFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(rightText(w))
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 86, alignment: .trailing)
                .help(w.resetsAt.map { "Resets \(Format.dateTime($0))" } ?? "")
        }
    }

    private func rightText(_ w: UsageWindow) -> String {
        if w.hasLimit, let detail = w.detail, w.resetsAt == nil { return detail }
        return Format.countdown(to: w.resetsAt, from: store.now) ?? (w.hasLimit ? "" : "")
    }

    private func paceRow(_ projected: Double, window: UsageWindow) -> some View {
        let verdict = PaceVerdict.from(projected: projected)
        return HStack(spacing: 10) {
            Text("Pace")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 62, alignment: .leading)
            UsageBarView(percent: projected, color: verdict.color)
            Text(Format.percent(projected))
                .font(Theme.numberFont)
                .foregroundStyle(verdict.color)
                .frame(width: 48, alignment: .trailing)
            Text(expanded ? verdict.rawValue : "projected")
                .font(.system(size: 13))
                .foregroundStyle(expanded ? verdict.color : Theme.textSecondary)
                .frame(width: 86, alignment: .trailing)
                .help("Projected \(window.label) usage at reset if the current rate continues")
        }
    }

    private func extraRow(_ extra: ExtraUsage) -> some View {
        HStack(spacing: 10) {
            Text(extra.title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
            if let pct = extra.percent {
                UsageBarView(percent: pct, color: Severity.from(percent: pct).color)
                Text(Format.percent(pct))
                    .font(Theme.numberFont)
                    .foregroundStyle(Severity.from(percent: pct).color)
                    .frame(width: 48, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
            Text(extra.detail)
                .font(Theme.smallNumberFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: extra.percent == nil ? nil : 86, alignment: .trailing)
        }
    }

    private func footer(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let acct = snap.accountLabel {
                Text(acct).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            HStack(spacing: 6) {
                if let reset = snap.primaryWindows.compactMap(\.resetsAt).min() {
                    Text("Next reset \(Format.dateTime(reset))")
                }
                if let note = snap.note { Text("· \(note)") }
                Spacer()
                Text("Updated \(Format.relative(snap.fetchedAt, now: store.now))")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
        }
        .padding(.top, 2)
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}
