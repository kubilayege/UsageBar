import SwiftUI
import Charts

struct UsageCostChart: View {
    let plot: AnalysisCostPlot
    let start: Date
    let end: Date
    @Binding var resolution: AnalysisCostResolution
    var onFixPrices: (() -> Void)?
    /// Hover lives here, outside the heavy chart, so moving the mouse never rebuilds thousands of marks.
    @State private var hover: CostChartHover?
    /// Series isolated by clicking legend chips. Empty means everything is shown at full strength.
    @State private var focus: Set<String> = []

    private let series: [AnalysisRow]
    private let groups: [(model: String, provider: ProviderID, rows: [AnalysisRow])]
    private let labels: [String: String]
    private let symbols: [String: BasicChartSymbolShape]
    private let legend: [String]
    private let colors: [Color]
    private let singleModel: Bool
    private let ceiling: Double

    private static let symbolShapes: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .plus, .cross, .pentagon, .asterisk]

    init(plot: AnalysisCostPlot, start: Date, end: Date, resolution: Binding<AnalysisCostResolution>, onFixPrices: (() -> Void)? = nil) {
        self.plot = plot
        self.start = start
        self.end = end
        self._resolution = resolution
        self.onFixPrices = onFixPrices
        let series = Dictionary(grouping: plot.points, by: { $0.row.id }).values.compactMap { $0.first?.row }.sorted {
            if $0.model != $1.model { return $0.model < $1.model }
            let left = EffortStyle.rank($0.effort), right = EffortStyle.rank($1.effort)
            return left == right ? $0.id < $1.id : left < right
        }
        self.series = series
        var groups: [(model: String, provider: ProviderID, rows: [AnalysisRow])] = []
        for row in series {
            let key = row.provider.rawValue + "/" + row.model
            if let i = groups.firstIndex(where: { $0.provider.rawValue + "/" + $0.model == key }) { groups[i].rows.append(row) }
            else { groups.append((row.model, row.provider, [row])) }
        }
        self.groups = groups
        singleModel = groups.count == 1
        ceiling = max(0.001, (plot.points.compactMap { $0.row.costPerTurn }.max() ?? 0) * 1.12)
        var labels: [String: String] = [:], symbols: [String: BasicChartSymbolShape] = [:]
        for row in series {
            let effort = EffortStyle.label(row.effort)
            let modelIndex = groups.firstIndex { $0.provider == row.provider && $0.model == row.model } ?? 0
            symbols[row.id] = Self.symbolShapes[modelIndex % Self.symbolShapes.count]
            if singleModel { labels[row.id] = effort; continue }
            let redundant = row.model.lowercased().hasPrefix(row.provider.rawValue)
            labels[row.id] = redundant ? "\(row.model) · \(effort)" : "\(row.provider.displayName) · \(row.model) · \(effort)"
        }
        self.labels = labels
        self.symbols = symbols
        legend = series.map { labels[$0.id]! }
        colors = series.map { EffortStyle.color($0.effort) }
    }
    private var selected: AnalysisCostPoint? { hover.flatMap { h in plot.points.first { $0.id == h.id } } }
    private var activeFocus: Set<String> { focus.intersection(series.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Estimated API cost per turn").font(.system(size: 15, weight: .semibold))
                    Text(resolution == .average
                         ? "\(plot.isHourly ? "Hourly" : "Daily") mean per model and effort. Larger marks carry more turns."
                         : "One mark per recorded assistant response, including tool-use responses.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 12)
                Picker("Plot", selection: $resolution) {
                    Text(plot.isHourly ? "Hourly average" : "Daily average").tag(AnalysisCostResolution.average)
                    Text("Each turn").tag(AnalysisCostResolution.turns)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 210)
            }
            if plot.points.isEmpty {
                VStack(spacing: 10) {
                    Text("Nothing to plot yet").font(.system(size: 13, weight: .semibold))
                    Text("Only turns with a complete price are drawn. Unknown prices are never shown as $0.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    if let onFixPrices {
                        Button("Add prices") { onFixPrices() }.buttonStyle(ChipButtonStyle()).font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200, alignment: .center)
            } else {
                CostChartCanvas(points: plot.points, labels: labels, legend: legend, colors: colors, symbols: symbols,
                                focus: activeFocus, resolution: resolution, start: start, end: end, ceiling: ceiling,
                                isHourly: plot.isHourly, height: singleModel ? 250 : 280, onHover: hovered)
                    .equatable()
                    .overlay { selectionLayer.allowsHitTesting(false) }
                legendView
                inspection
            }
            if plot.omittedTurns > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text("\(plot.omittedTurns) turns not plotted: \(resolution == .average ? "their period includes" : "they use") a model without a complete price.")
                    if let onFixPrices { Button("Add prices", action: onFixPrices).buttonStyle(.plain).underline() }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.caution)
            }
        }
        .padding(18).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .onChange(of: resolution) { _, _ in hover = nil }
        .onChange(of: start) { _, _ in hover = nil }
        .onChange(of: end) { _, _ in hover = nil }
    }

    // MARK: Legend

    /// One row per model; each effort is a chip in the chart's color and mark shape. Click a chip to isolate it.
    private var legendView: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                ForEach(groups, id: \.model) { group in
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            ProviderDot(id: group.provider, size: 6)
                            Text(group.model).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        .padding(.leading, 4).padding(.trailing, 2)
                        .onTapGesture { toggle(group.rows.map(\.id)) }
                        ForEach(group.rows) { row in
                            legendChip(row)
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
                }
            }
            if !activeFocus.isEmpty {
                Button { withAnimation(.snappy) { focus = [] } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        Text("Show all \(series.count) series").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text("Click an effort to isolate it, or a model name to isolate all of its efforts.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func legendChip(_ row: AnalysisRow) -> some View {
        let color = EffortStyle.color(row.effort)
        let dimmed = !activeFocus.isEmpty && !activeFocus.contains(row.id)
        return Button { toggle([row.id]) } label: {
            HStack(spacing: 5) {
                (symbols[row.id] ?? .circle).path(in: CGRect(x: 0, y: 0, width: 8, height: 8))
                    .fill(color).frame(width: 8, height: 8)
                Text(EffortStyle.label(row.effort)).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(dimmed ? Theme.textMuted : Theme.textPrimary)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(dimmed ? .clear : color.opacity(0.14)))
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(dimmed ? "Show \(labels[row.id] ?? row.model)" : "Isolate \(labels[row.id] ?? row.model)")
    }

    private func toggle(_ ids: [String]) {
        withAnimation(.snappy) {
            let set = Set(ids)
            if activeFocus == set { focus = [] }
            else if activeFocus.isSuperset(of: set) && !activeFocus.isEmpty && activeFocus != set { focus.subtract(set) }
            else if activeFocus.isEmpty { focus = set }
            else { focus.formUnion(set) }
            hover = nil
        }
    }

    // MARK: Selection & inspection

    /// Selection indicator drawn with plain shapes; both scales are linear so no chart proxy is needed.
    @ViewBuilder private var selectionLayer: some View {
        if let hover, let point = selected, let cost = point.row.costPerTurn {
            let frame = hover.plotFrame
            let x = frame.minX + point.timestamp.timeIntervalSince(start) / max(1, end.timeIntervalSince(start)) * frame.width
            let y = frame.maxY - cost / ceiling * frame.height
            Path { path in
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
            }
            .stroke(Theme.textMuted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            Circle().fill(EffortStyle.color(point.row.effort)).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Theme.bg, lineWidth: 2.5))
                .position(x: x, y: y)
        }
    }

    private func hovered(_ input: CostChartHoverInput?) {
        guard let input else { if hover != nil { hover = nil }; return }
        let id = nearest(to: input.date, cost: input.cost, size: input.plotFrame.size)?.id
        let next = id.map { CostChartHover(id: $0, plotFrame: input.plotFrame) }
        if next != hover { hover = next }
    }

    private var inspection: some View {
        Group {
            if let point = selected {
                let row = point.row
                let input = row.input + row.cached + row.cacheWrite
                let cached = input > 0 ? String(format: "%.0f%%", 100 * Double(row.cached) / Double(input)) : "—"
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    HStack(spacing: 6) {
                        ProviderDot(id: row.provider, size: 6)
                        Text(row.model).font(.system(size: 12, weight: .semibold))
                        EffortPill(effort: row.effort)
                    }
                    Text(period(point)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    stat(money(row.costPerTurn), "per turn", strong: true)
                    stat("\(row.turns)", row.turns == 1 ? "turn" : "turns", tint: row.turns < 5 && resolution == .average ? Theme.caution : nil)
                    stat(Format.tokens(Int(row.tokensPerTurn)), "tokens / turn")
                    stat(Format.tokens(row.input / max(1, row.turns)), "uncached in")
                    stat(Format.tokens(row.output / max(1, row.turns)), "out")
                    stat(cached, "cached")
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    Text("Hover the plot to compare efforts at a point in time.").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected == nil ? 0.02 : 0.04)))
    }

    private func stat(_ value: String, _ label: String, strong: Bool = false, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: strong ? 13 : 12, weight: strong ? .bold : .semibold, design: .monospaced))
                .foregroundStyle(tint ?? Theme.textPrimary)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
    }

    private func nearest(to date: Date, cost: Double, size: CGSize) -> AnalysisCostPoint? {
        let duration = max(1, end.timeIntervalSince(start))
        let candidates = activeFocus.isEmpty ? plot.points : plot.points.filter { activeFocus.contains($0.row.id) }
        func distance(_ point: AnalysisCostPoint) -> Double {
            let x = point.timestamp.timeIntervalSince(date) / duration * size.width
            let y = ((point.row.costPerTurn ?? 0) - cost) / ceiling * size.height
            return x * x + y * y
        }
        return candidates.min { distance($0) < distance($1) }
    }

    static func color(_ row: AnalysisRow) -> Color { EffortStyle.color(row.effort) }

    private func period(_ point: AnalysisCostPoint) -> String {
        if resolution == .turns { return Format.dateTime(point.timestamp) }
        let from = point.start.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let to = point.end.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(from) – \(to)"
    }
    private func money(_ value: Double?) -> String { value.map { String(format: "$%.4f", $0) } ?? "—" }
}

struct CostChartHover: Equatable { var id: String; var plotFrame: CGRect }
struct CostChartHoverInput { var date: Date; var cost: Double; var plotFrame: CGRect }

/// The marks only. Equatable so SwiftUI skips rebuilding it while hover or unrelated state changes.
private struct CostChartCanvas: View, Equatable {
    let points: [AnalysisCostPoint]
    let labels: [String: String]
    let legend: [String]
    let colors: [Color]
    let symbols: [String: BasicChartSymbolShape]
    let focus: Set<String>
    let resolution: AnalysisCostResolution
    let start: Date
    let end: Date
    let ceiling: Double
    let isHourly: Bool
    let height: CGFloat
    let onHover: (CostChartHoverInput?) -> Void

    static func == (a: CostChartCanvas, b: CostChartCanvas) -> Bool {
        a.resolution == b.resolution && a.start == b.start && a.end == b.end && a.ceiling == b.ceiling
            && a.isHourly == b.isHourly && a.height == b.height && a.legend == b.legend && a.colors == b.colors
            && a.labels == b.labels && a.focus == b.focus && a.points == b.points
    }

    private func opacity(_ row: AnalysisRow) -> Double {
        let base = resolution == .turns ? 0.55 : 1
        return focus.isEmpty || focus.contains(row.id) ? base : 0.08
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                if let cost = point.row.costPerTurn {
                    let label = labels[point.row.id] ?? point.row.model
                    let alpha = opacity(point.row)
                    if resolution == .average {
                        LineMark(x: .value("Time", point.timestamp), y: .value("USD / turn", cost),
                                 series: .value("Segment", point.segment))
                            .foregroundStyle(by: .value("Model / effort", label))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .opacity(alpha)
                    }
                    PointMark(x: .value("Time", point.timestamp), y: .value("USD / turn", cost))
                        .foregroundStyle(by: .value("Model / effort", label))
                        .symbol(by: .value("Model / effort", label))
                        .symbolSize(resolution == .turns ? 18 : point.row.turns < 5 ? 22 : point.row.turns < 30 ? 42 : 68)
                        .opacity(alpha)
                        .accessibilityLabel("\(label), \(Format.dateTime(point.start))")
                        .accessibilityValue("\(String(format: "$%.4f", cost)) per turn, \(point.row.turns) turns")
                }
            }
        }
        .chartForegroundStyleScale(domain: legend, range: colors)
        .chartSymbolScale(domain: legend, range: legend.indices.map { index in
            let id = points.first { labels[$0.row.id] == legend[index] }?.row.id
            return id.flatMap { symbols[$0] } ?? .circle
        })
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ceiling)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.divider)
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(String(format: ceiling < 0.02 ? "$%.3f" : "$%.2f", cost))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(Theme.divider)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: isHourly ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                            .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let location) = phase, let anchor = proxy.plotFrame else { onHover(nil); return }
                        let frame = geometry[anchor]
                        guard frame.contains(location),
                              let date: Date = proxy.value(atX: location.x - frame.minX),
                              let cost: Double = proxy.value(atY: location.y - frame.minY) else { onHover(nil); return }
                        onHover(CostChartHoverInput(date: date, cost: cost, plotFrame: frame))
                    }
            }
        }
        .frame(height: height)
    }
}
