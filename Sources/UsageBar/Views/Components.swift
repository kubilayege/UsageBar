import SwiftUI

// MARK: - Window meter

/// One usage window on a single track: the fill is usage, the needle is how far through the
/// window you are, and the hatched run is where the current pace lands at reset.
struct WindowMeter: View {
    var percent: Double
    var color: Color
    /// Fraction of the window already elapsed, 0...1.
    var elapsed: Double? = nil
    /// Projected percent at reset.
    var projected: Double? = nil
    var height: CGFloat = 8

    private var overhang: CGFloat { max(3, height * 0.4) }

    var body: some View {
        Canvas { ctx, size in
            let track = CGRect(x: 0, y: overhang, width: size.width, height: height)
            let radius = min(2.5, height / 3)
            ctx.fill(Path(roundedRect: track, cornerRadius: radius), with: .color(Theme.well))
            for q in [0.25, 0.5, 0.75] {
                ctx.fill(Path(CGRect(x: track.width * q - 0.5, y: track.minY + 2, width: 1, height: track.height - 4)),
                         with: .color(.white.opacity(0.07)))
            }
            let used = min(1, max(0, percent / 100))
            if let projected, projected > percent {
                let end = min(1, projected / 100)
                let ghost = CGRect(x: track.width * used, y: track.minY, width: track.width * (end - used), height: track.height)
                let tint = Severity.from(percent: projected).color
                ctx.fill(Path(roundedRect: ghost, cornerRadius: radius), with: .color(tint.opacity(0.12)))
                var hatch = ctx
                hatch.clip(to: Path(roundedRect: ghost, cornerRadius: radius))
                var lines = Path()
                var x = ghost.minX - track.height
                while x < ghost.maxX {
                    lines.move(to: CGPoint(x: x, y: track.maxY))
                    lines.addLine(to: CGPoint(x: x + track.height, y: track.minY))
                    x += 4
                }
                hatch.stroke(lines, with: .color(tint.opacity(0.55)), lineWidth: 1)
            }
            if used > 0 {
                let fill = CGRect(x: 0, y: track.minY, width: max(radius * 2, track.width * used), height: track.height)
                ctx.fill(Path(roundedRect: fill, cornerRadius: radius), with: .color(color))
            }
            if let elapsed {
                let x = min(track.width - 1, max(1, track.width * elapsed))
                ctx.fill(Path(CGRect(x: x - 1.75, y: 0, width: 3.5, height: size.height)), with: .color(.black.opacity(0.55)))
                ctx.fill(Path(roundedRect: CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height), cornerRadius: 0.75),
                         with: .color(Theme.textPrimary))
            }
        }
        .frame(height: height + overhang * 2)
        .accessibilityHidden(true)
    }
}

/// Explains the meter's marks once, wherever meters appear.
struct MeterKey: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 0.75).fill(Theme.textPrimary).frame(width: 1.5, height: 10)
                Text("time elapsed")
            }
            HStack(spacing: 5) {
                WindowMeter(percent: 0, color: .clear, projected: 100, height: 6).frame(width: 16)
                Text("projected by reset")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textMuted)
    }
}

// MARK: - Provider status

/// A short verdict for one provider: at limit, runs out soon, tight, or on pace.
enum ProviderStatus {
    static func of(_ snap: UsageSnapshot, now: Date) -> (text: String, color: Color) {
        let v = verdict(snap, now: now)
        return (v.text, v.color)
    }

    /// The most urgent verdict across several accounts of one provider.
    static func worst(_ snaps: [UsageSnapshot], now: Date) -> (text: String, color: Color)? {
        guard let v = snaps.map({ verdict($0, now: now) }).max(by: { $0.rank < $1.rank }) else { return nil }
        return (v.text, v.color)
    }

    /// `rank` orders verdicts by urgency; a sooner run-out ranks higher.
    private static func verdict(_ snap: UsageSnapshot, now: Date) -> (text: String, color: Color, rank: Double) {
        let limited = snap.primaryWindows.filter(\.hasLimit)
        guard !limited.isEmpty else { return ("Tracking", Theme.textSecondary, 0) }
        if limited.contains(where: { $0.percent >= 100 }) { return ("At limit", Theme.critical, 5) }
        if let out = limited.compactMap({ $0.exhaustion(now: now) }).min() {
            let left = out.timeIntervalSince(now)
            return ("Out in \(Format.span(left))", left < 3600 ? Theme.critical : Theme.warning, 4 - left / (left + 86400))
        }
        let worst = limited.map(\.severity).max() ?? .ok
        if limited.compactMap({ $0.projection(now: now) }).contains(where: { $0 >= 85 }) { return ("Tight", Theme.caution, 2.5) }
        if worst >= .warning { return ("\(Format.percent(limited.map(\.percent).max() ?? 0)) used", worst.color, 2) }
        return ("On pace", Theme.ok, 1)
    }
}

// MARK: - Surfaces and controls

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View { content.padding(padding).panel() }
}

extension View {
    /// A raised surface: solid fill with a faint top highlight, no outline.
    func panel(_ fill: Color = Theme.panel, radius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.015)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

struct ChipButtonStyle: ButtonStyle {
    /// Bone fill with dark text: the one primary action in a group.
    var prominent = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Theme.onBone : Theme.textPrimary)
            .padding(.horizontal, compact ? 8 : 11)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Theme.textPrimary : Theme.chipFill)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Uppercase expanded label used for section legends, like the engraving on a panel.
struct Legend: View {
    var text: String
    var color: Color = Theme.textMuted
    init(_ text: String, color: Color = Theme.textMuted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(Theme.legend).tracking(0.9).foregroundStyle(color).lineLimit(1)
    }
}

/// Title row shared by every dashboard page.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.14)))
    }
}

struct ProviderDot: View {
    var id: ProviderID
    var size: CGFloat = 8
    var body: some View { Circle().fill(id.color).frame(width: size, height: size) }
}

/// A row of readouts in one panel, split by hairlines. The first can lead.
struct ReadoutStrip: View {
    struct Item: Identifiable {
        var value: String
        var label: String
        var tint: Color = Theme.textPrimary
        var id: String { label }
    }
    var items: [Item]
    var leadSize: CGFloat = 30

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(Theme.line).frame(width: 1, height: 34) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.value).font(Theme.readout(index == 0 ? leadSize : 22)).foregroundStyle(item.tint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(item.label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, 16)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 14)
        .panel()
    }
}

/// Small square icon button used in lists.
struct IconButton: View {
    var systemImage: String
    var help: String
    var tint: Color = Theme.textSecondary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(hover ? Theme.textPrimary : tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.white.opacity(0.1) : Theme.chipFill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Left-aligned wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

enum RenderFlags {
    /// True while `--render-preview` runs; ScrollViews are AppKit-backed and invisible to ImageRenderer.
    nonisolated(unsafe) static var isRendering = false
    /// `--analysis-hover N` pretends the pointer rests on the Nth plotted mark (negative counts from the end), to render the chart tooltip.
    nonisolated(unsafe) static var previewHoverIndex: Int?
}

/// ScrollView in the app, plain content while rendering previews.
struct MaybeScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if RenderFlags.isRendering { content } else { ScrollView { content } }
    }
}

// MARK: - Live session row

struct LiveSessionRow: View {
    var session: LiveSession
    var now: Date
    @State private var hover = false

    private var openHelp: String {
        let cmd = SessionReveal.resumeCommand(session).map { " (\($0))" } ?? ""
        return "Open a terminal here and resume this session\(cmd). Jumps to the existing window if the agent is still running. Right-click for options."
    }

    var body: some View {
        let live = session.isLive(now: now)
        HStack(spacing: 10) {
            ZStack {
                if live { Circle().fill(Theme.ok.opacity(0.22)).frame(width: 14, height: 14) }
                Circle().fill(live ? Theme.ok : session.isProcessRunning ? Theme.textSecondary : Theme.textMuted.opacity(0.6))
                    .frame(width: 6, height: 6)
            }
            .frame(width: 14)
            .help(live ? "Writing now" : session.isProcessRunning ? "Running, idle" : "Recently active")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let b = session.branch {
                        Text(b).font(Theme.mono(10.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Text(session.provider.displayName)
                    if let m = session.model { Text("· \(m)") }
                    if let t = session.tokens { Text("· \(Format.tokens(t)) \(session.tokensLabel)") }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(live ? "live" : Format.relative(session.lastActivity, now: now))
                .font(.system(size: 11, weight: live ? .semibold : .regular))
                .foregroundStyle(live ? Theme.ok : Theme.textSecondary)
            Button { SessionReveal.reveal(session) } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hover ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.white.opacity(0.1) : Theme.chipFill))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(openHelp)
            .accessibilityLabel("Open \(session.project) in a terminal")
            .contextMenu {
                Button("Resume in New Terminal") { SessionReveal.resumeInTerminal(session) }
                Button("Show Running Agent") { SessionReveal.reveal(session) }
                Divider()
                Button("Copy Resume Command") { SessionReveal.copyResumeCommand(session) }
            }
        }
        .padding(.vertical, 5)
        .help(session.cwd)
    }
}
