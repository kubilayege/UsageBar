import SwiftUI

struct UsageBarView: View {
    var percent: Double
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * CGFloat(min(100, max(0, percent)) / 100)))
                    .animation(.easeOut(duration: 0.35), value: percent)
            }
        }
        .frame(height: height)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var selected = false
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.chipSelected : Theme.chipFill)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.chipSelectedStroke : Theme.cardStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

struct Badge: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ProviderDot: View {
    var id: ProviderID
    var size: CGFloat = 12
    var body: some View { Circle().fill(id.color).frame(width: size, height: size) }
}

struct StatTile: View {
    var value: String
    var label: String
    var tint: Color = Theme.textPrimary
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
}

/// ScrollView in the app, plain content while rendering previews.
struct MaybeScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if RenderFlags.isRendering { content } else { ScrollView { content } }
    }
}

struct LiveSessionRow: View {
    var session: LiveSession
    var now: Date
    @State private var hoverOpen = false

    private var openHelp: String {
        let cmd = SessionReveal.resumeCommand(session).map { " (\($0))" } ?? ""
        return "Open a terminal here and resume this session\(cmd). Jumps to the existing window if the agent is still running. Right-click for options."
    }

    var body: some View {
        let live = session.isLive(now: now)
        HStack(spacing: 10) {
            ProviderDot(id: session.provider, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let b = session.branch {
                        Text(b).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Text(session.provider.displayName).foregroundStyle(session.provider.color.opacity(0.9))
                    if let m = session.model { Text("· \(m)") }
                    if let t = session.tokens { Text("· \(Format.tokens(t)) \(session.tokensLabel)") }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    if live {
                        Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        Text("live").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ok)
                    } else if session.isProcessRunning {
                        Text("idle").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                    }
                }
                Text(Format.relative(session.lastActivity, now: now)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            Button { SessionReveal.reveal(session) } label: {
                Image(systemName: "apple.terminal")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hoverOpen ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hoverOpen ? Color.white.opacity(0.1) : Theme.chipFill))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hoverOpen = $0 }
            .help(openHelp)
            .contextMenu {
                Button("Resume in New Terminal") { SessionReveal.resumeInTerminal(session) }
                Button("Show Running Agent") { SessionReveal.reveal(session) }
                Divider()
                Button("Copy Resume Command") { SessionReveal.copyResumeCommand(session) }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .help(session.cwd)
    }
}
