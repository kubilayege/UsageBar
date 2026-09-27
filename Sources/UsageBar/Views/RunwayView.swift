import SwiftUI

/// The headline: which limit cuts you off first, and when.
struct RunwayView: View {
    enum Size { case popover, compact, dashboard }
    var runway: Runway
    var now: Date
    var size: Size = .popover

    var body: some View {
        if let lead = runway.lead {
            switch size {
            case .compact: compactLine(lead)
            case .popover: full(lead, readout: 34, sentence: 12.5)
            case .dashboard: full(lead, readout: 52, sentence: 14)
            }
        }
    }

    private func full(_ lead: Runway.Item, readout: CGFloat, sentence: CGFloat) -> some View {
        let others = runway.alerts.filter { $0.id != lead.id }
        return VStack(alignment: .leading, spacing: size == .dashboard ? 10 : 6) {
            HStack(spacing: 6) {
                Circle().fill(Self.color(lead)).frame(width: 6, height: 6)
                Legend("\(lead.name) · \(Self.verdict(lead))", color: Self.color(lead))
            }
            HStack(alignment: .firstTextBaseline, spacing: size == .dashboard ? 18 : 12) {
                Text(Self.readout(lead))
                    .font(Theme.readout(readout, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
                Text(Self.sentence(lead))
                    .font(.system(size: sentence))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if size == .dashboard, !others.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(others.prefix(6)) { item in
                        HStack(spacing: 6) {
                            Circle().fill(Self.color(item)).frame(width: 5, height: 5)
                            Text(item.name).foregroundStyle(Theme.textSecondary)
                            Text(Self.short(item)).foregroundStyle(Self.color(item)).fontWeight(.semibold)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.chipFill))
                    }
                }
                .padding(.top, 2)
            } else if let next = others.first {
                Text("Also: \(next.name) \(Self.short(next).lowercased())\(others.count > 1 ? ", plus \(others.count - 1) more" : "").")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func compactLine(_ lead: Runway.Item) -> some View {
        HStack(spacing: 7) {
            Circle().fill(Self.color(lead)).frame(width: 6, height: 6)
            Text(lead.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(Self.short(lead)).font(.system(size: 12)).foregroundStyle(Self.color(lead))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    // MARK: Copy

    static func verdict(_ item: Runway.Item) -> String {
        switch item.kind {
        case .blocked: return "At limit"
        case .runsOut: return "Runs out"
        case .clear: return (item.projected ?? 0) >= 85 ? "Tight" : "On pace"
        }
    }

    static func readout(_ item: Runway.Item) -> String {
        switch item.kind {
        case .blocked, .runsOut: return item.remaining.map(Format.span) ?? "—"
        case .clear: return item.projected.map { Format.percent(min(999, $0)) } ?? "—"
        }
    }

    static func sentence(_ item: Runway.Item) -> String {
        switch item.kind {
        case .blocked:
            guard let reset = item.window.resetsAt else { return "\(item.name) is at its limit." }
            return "until \(item.name) resets on \(Format.dateTime(reset))."
        case .runsOut:
            let gap = item.gap.map { ", \(Format.span($0)) before it resets" } ?? ""
            return "until \(item.name) runs out at this pace\(gap)."
        case .clear:
            return "projected for \(item.name) at its reset. No limit runs out before resetting."
        }
    }

    /// "at its limit", "runs out in 38m", "ends near 81%".
    static func short(_ item: Runway.Item) -> String {
        switch item.kind {
        case .blocked: return item.remaining.map { "At limit · resets in \(Format.span($0))" } ?? "At limit"
        case .runsOut: return "Runs out in \(item.remaining.map(Format.span) ?? "—")"
        case .clear: return "Ends near \(item.projected.map { Format.percent($0) } ?? "—")"
        }
    }

    static func color(_ item: Runway.Item) -> Color {
        switch item.kind {
        case .blocked: return Theme.critical
        case .runsOut: return (item.remaining ?? 0) < 3600 ? Theme.critical : Theme.warning
        case .clear: return PaceVerdict.from(projected: item.projected ?? 0).color
        }
    }
}
