import SwiftUI

/// One account: a header with its verdict, then one meter per window.
struct ProviderCardView: View {
    @EnvironmentObject var store: UsageStore
    var account: Account
    var compact = false
    /// Dashboard layout: secondary windows, taller meters and a details footer.
    var expanded = false

    private var id: ProviderID { account.provider }
    /// Only named when the provider has several accounts; otherwise the card looks as it always has.
    private var accountName: String? { store.hasSeveralAccounts(id) ? store.label(account) : nil }
    private var state: ProviderState { store.state(account) }
    private var snapshot: UsageSnapshot? { state.snapshot }
    private var labelWidth: CGFloat { expanded ? 58 : 46 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            header.padding(.bottom, compact ? 0 : 2)
            if let snap = snapshot {
                ForEach(snap.primaryWindows) { row($0) }
                if expanded { ForEach(snap.secondaryWindows) { row($0) } }
                if let extra = snap.extraUsage { extraRow(extra) }
                if let resets = snap.bankedResets { bankedRow(resets) }
                if expanded { footer(snap) }
            }
            stateMessage
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Text(id.displayName)
                .font(.system(size: expanded ? 15 : 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .layoutPriority(1)
            if let accountName {
                Text(accountName)
                    .font(.system(size: expanded ? 13 : 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(account.email.map { "\($0) · \(account.sourceDescription)" } ?? account.sourceDescription)
            }
            if let plan = snapshot?.planName {
                Text(plan).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            if id.isExperimental { Badge(text: "beta", color: Theme.textMuted) }
            Spacer(minLength: 6)
            if state.isLoading { ProgressView().controlSize(.mini) }
            if let snap = snapshot {
                let status = ProviderStatus.of(snap, now: store.now)
                Text(status.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.color)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ w: UsageWindow) -> some View {
        Group {
            if expanded && w.hasLimit { stackedRow(w) } else { inlineRow(w) }
        }
        .help(help(w))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.title(account)) \(w.label)")
        .accessibilityValue(help(w))
    }

    /// Popup: label, meter, percent and countdown on one line.
    private func inlineRow(_ w: UsageWindow) -> some View {
        HStack(spacing: 10) {
            Text(w.label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if w.hasLimit {
                WindowMeter(percent: w.percent, color: w.severity.color,
                            elapsed: compact ? nil : w.elapsedFraction(now: store.now),
                            projected: compact ? nil : w.projection(now: store.now))
                Text(Format.percent(w.percent))
                    .font(Theme.readout(14))
                    .foregroundStyle(w.severity.color)
                    .frame(width: 44, alignment: .trailing)
                Text(resetText(w))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .frame(width: 74, alignment: .trailing)
            } else {
                Text(w.detail ?? "—")
                    .font(Theme.mono(11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    /// Dashboard: the numbers sit above a full-width meter.
    private func stackedRow(_ w: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(w.label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(Format.percent(w.percent)).font(Theme.readout(17)).foregroundStyle(w.severity.color)
                Spacer(minLength: 8)
                Text(paceText(w)).font(.system(size: 11.5)).foregroundStyle(paceColor(w)).lineLimit(1)
                if let reset = w.resetsAt {
                    Text("resets in \(Format.span(reset.timeIntervalSince(store.now)))")
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else if let detail = w.detail {
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            WindowMeter(percent: w.percent, color: w.severity.color,
                        elapsed: w.elapsedFraction(now: store.now), projected: w.projection(now: store.now), height: 10)
        }
        .padding(.bottom, 4)
    }

    private func paceText(_ w: UsageWindow) -> String {
        if w.percent >= 100 { return "" }
        if let out = w.exhaustion(now: store.now) { return "out in \(Format.span(out.timeIntervalSince(store.now))) ·" }
        if let p = w.projection(now: store.now) { return "ends near \(Format.percent(p)) ·" }
        return ""
    }

    private func paceColor(_ w: UsageWindow) -> Color {
        if let out = w.exhaustion(now: store.now) { return out.timeIntervalSince(store.now) < 3600 ? Theme.critical : Theme.warning }
        return Theme.textMuted
    }

    private func resetText(_ w: UsageWindow) -> String {
        if let detail = w.detail, w.resetsAt == nil { return detail }
        guard let reset = w.resetsAt else { return "" }
        return Format.span(reset.timeIntervalSince(store.now))
    }

    private func help(_ w: UsageWindow) -> String {
        guard w.hasLimit else { return w.detail ?? w.label }
        var parts = ["\(Format.percent(w.percent)) of the \(w.label) limit used."]
        if let e = w.elapsedFraction(now: store.now) { parts.append("\(Format.percent(e * 100)) of the window has passed.") }
        if let out = w.exhaustion(now: store.now) {
            parts.append("At this pace it runs out in \(Format.span(out.timeIntervalSince(store.now))), at \(Format.clock(out)).")
        } else if let p = w.projection(now: store.now) {
            parts.append("At this pace it ends near \(Format.percent(p)).")
        }
        if let reset = w.resetsAt { parts.append("Resets \(Format.dateTime(reset)).") }
        return parts.joined(separator: " ")
    }

    @ViewBuilder private func extraRow(_ extra: ExtraUsage) -> some View {
        if expanded, let pct = extra.percent {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(extra.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Text(Format.percent(pct)).font(Theme.readout(17)).foregroundStyle(Severity.from(percent: pct).color)
                    Spacer(minLength: 8)
                    Text(extra.detail).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                WindowMeter(percent: pct, color: Severity.from(percent: pct).color, height: 10)
            }
            .padding(.bottom, 4)
            .help("Extra usage beyond the plan: \(extra.detail)")
        } else {
            inlineExtraRow(extra)
        }
    }

    private func inlineExtraRow(_ extra: ExtraUsage) -> some View {
        HStack(spacing: 10) {
            Text(extra.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if let pct = extra.percent {
                WindowMeter(percent: pct, color: Severity.from(percent: pct).color)
                Text(Format.percent(pct))
                    .font(Theme.readout(14))
                    .foregroundStyle(Severity.from(percent: pct).color)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
            Text(extra.detail)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: extra.percent == nil ? nil : 74, alignment: .trailing)
        }
        .help("Extra usage beyond the plan: \(extra.detail)")
    }

    private func bankedRow(_ resets: BankedResets) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 10.5, weight: .semibold))
            Text("\(resets.available) banked \(resets.available == 1 ? "reset" : "resets")")
            if let applicable = resets.applicable {
                Text("· \(applicable) usable now").foregroundStyle(Theme.textMuted)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.textSecondary)
        .padding(.leading, expanded ? 0 : labelWidth + 10)
        .help("Reset credits reported by Codex. Usable counts depend on the current limit. UsageBar never spends them.")
    }

    private func footer(_ snap: UsageSnapshot) -> some View {
        HStack(spacing: 6) {
            if let reset = snap.primaryWindows.compactMap(\.resetsAt).min() {
                Text("Next reset \(Format.dateTime(reset))").layoutPriority(1)
            }
            if let note = snap.note { Text("· \(note)") }
            Spacer(minLength: 8)
            // With several accounts the header already names this one; its email is in the header tooltip.
            if accountName == nil, let acct = snap.accountLabel { Text(acct).lineLimit(1).truncationMode(.middle) ; Text("·") }
            Text("Updated \(Format.relative(snap.fetchedAt, now: store.now))")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textMuted)
        .lineLimit(1)
        .padding(.top, 4)
    }

    // MARK: States

    @ViewBuilder private var stateMessage: some View {
        if let msg = state.errorMessage {
            message(msg, icon: "exclamationmark.triangle.fill", color: Theme.caution)
        } else if case .cooldown(let until, let stale) = state, expanded || stale == nil {
            message("The API asked UsageBar to slow down. Retrying in \(Format.countdown(to: until, from: store.now) ?? "a moment").",
                    icon: "clock", color: Theme.textMuted)
        } else if case .notConfigured(let msg) = state {
            message(msg, icon: "person.crop.circle.badge.questionmark", color: Theme.textMuted)
        } else if case .loading(nil) = state {
            message("Loading…", icon: "hourglass", color: Theme.textMuted)
        } else if case .idle = state {
            message("Waiting for the first refresh…", icon: "hourglass", color: Theme.textMuted)
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10.5))
            Text(text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }
}
