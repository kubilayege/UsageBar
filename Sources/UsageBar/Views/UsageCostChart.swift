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

    private let series: [AnalysisRow]
    private let labels: [String: String]
    private let legend: [String]
    private let colors: [Color]
    private let singleModel: Bool
    private let ceiling: Double

    init(plot: AnalysisCostPlot, start: Date, end: Date, resolution: Binding<AnalysisCostResolution>, onFixPrices: (() -> Void)? = nil) {
        self.plot = plot
        self.start = start
        self.end = end
        self._resolution = resolution
        self.onFixPrices = onFixPrices
        let series = Dictionary(grouping: plot.points, by: { $0.row.id }).values.compactMap { $0.first?.row }.sorted {
            if $0.model != $1.model { return $0.model < $1.model }
            let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            let left = efforts.firstIndex(of: $0.effort ?? "") ?? efforts.count
            let right = efforts.firstIndex(of: $1.effort ?? "") ?? efforts.count
            return left == right ? $0.id < $1.id : left < right
        }
        self.series = series
        singleModel = Set(series.map { $0.provider.rawValue + "/" + $0.model }).count == 1
        ceiling = max(0.001, (plot.points.compactMap { $0.row.costPerTurn }.max() ?? 0) * 1.12)
        var labels: [String: String] = [:]
        for row in series {
            let effort = row.effort ?? "Effort not recorded"
            if singleModel { labels[row.id] = effort; continue }
            // Skip the provider when the model name already carries it (claude-…, codex-…).
            let redundant = row.model.lowercased().hasPrefix(row.provider.rawValue)
            labels[row.id] = redundant ? "\(row.model) · \(effort)" : "\(row.provider.displayName) · \(row.model) · \(effort)"
        }
        self.labels = labels
        legend = series.map { labels[$0.id]! }
        colors = series.map(Self.color)
    }
    private var selected: AnalysisCostPoint? { hover.flatMap { h in plot.points.first { $0.id == h.id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated API cost per turn").font(.headline)
                    Text(resolution == .average
                         ? "\(plot.isHourly ? "Hourly" : "Daily") mean · total estimated cost ÷ recorded turns"
                         : "One dot per recorded assistant response · includes tool-use responses")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 12)
                Picker("Plot", selection: $resolution) {
                    Text(plot.isHourly ? "Hourly average" : "Daily average").tag(AnalysisCostResolution.average)
                    Text("Each turn").tag(AnalysisCostResolution.turns)
                }
                .pickerStyle(.segmented).frame(width: 238)
            }
            if plot.points.isEmpty {
                VStack(spacing: 8) {
                    Text("No priced turns to plot. Unknown prices are never shown as $0.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    if let onFixPrices {
                        Button("Add prices…", action: onFixPrices).buttonStyle(ChipButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            } else {
                CostChartCanvas(points: plot.points, labels: labels, legend: legend, colors: colors, resolution: resolution,
                                start: start, end: end, ceiling: ceiling, isHourly: plot.isHourly,
                                height: singleModel ? 260 : 290, onHover: hovered)
                    .equatable()
                    .overlay { selectionLayer.allowsHitTesting(false) }
                inspection
                Text(resolution == .average
                     ? "Larger dots have more turns. First and last periods may be partial; gaps have no fully priced observations. One rate per model across the range, not historical prices or your bill."
                     : "All priced turns are plotted, including outliers. One rate per model across the range, not historical prices or your bill.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
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
        .padding(16).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: resolution) { _, _ in hover = nil }
        .onChange(of: start) { _, _ in hover = nil }
        .onChange(of: end) { _, _ in hover = nil }
    }

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
            Circle().fill(Theme.textPrimary).frame(width: 11, height: 11)
                .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
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
        VStack(alignment: .leading, spacing: 5) {
            if let point = selected {
                HStack(spacing: 8) {
                    Circle().fill(Self.color(point.row)).frame(width: 7, height: 7)
                    Text(labels[point.row.id] ?? point.row.model).fontWeight(.semibold)
                    Text(money(point.row.costPerTurn) + " / turn").fontWeight(.semibold)
                    Text("· \(point.row.turns) \(point.row.turns == 1 ? "turn" : "turns")")
                        .foregroundStyle(point.row.turns < 5 && resolution == .average ? Theme.caution : Theme.textSecondary)
                    Spacer()
                    Text(period(point)).foregroundStyle(Theme.textSecondary)
                }
                let row = point.row
                let input = row.input + row.cached + row.cacheWrite
                let cached = input > 0 ? String(format: "%.1f%%", 100 * Double(row.cached) / Double(input)) : "—"
                Text("\(Format.tokens(Int(row.tokensPerTurn))) tokens / turn · \(Format.tokens(row.input / max(1, row.turns))) uncached input · \(Format.tokens(row.output / max(1, row.turns))) output · \(cached) of input cached\(row.turns < 5 && resolution == .average ? " · fewer than 5 observations" : "")")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Hover the plot to compare effort levels at a point in time.").foregroundStyle(Theme.textSecondary)
                Text("Cost, turn count, uncached input, output and cache share appear here.").foregroundStyle(Theme.textMuted)
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }

    private func nearest(to date: Date, cost: Double, size: CGSize) -> AnalysisCostPoint? {
        let duration = max(1, end.timeIntervalSince(start))
        func distance(_ point: AnalysisCostPoint) -> Double {
            let x = point.timestamp.timeIntervalSince(date) / duration * size.width
            let y = ((point.row.costPerTurn ?? 0) - cost) / ceiling * size.height
            return x * x + y * y
        }
        return plot.points.min { distance($0) < distance($1) }
    }

    static func color(_ row: AnalysisRow) -> Color {
        switch row.effort {
        case "none", "minimal": return Color(hex: 0xB6AEA8)
        case "low": return Color(hex: 0x87BE82)
        case "medium": return Color(hex: 0x73BCE8)
        case "high": return Color(hex: 0xE1C46B)
        case "xhigh": return Color(hex: 0xB29AEE)
        case "max": return Color(hex: 0xEE997A)
        case "ultra": return Color(hex: 0xE488B6)
        default: return Theme.textSecondary
        }
    }

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
            && a.labels == b.labels && a.points == b.points
    }

    private static let symbols: [BasicChartSymbolShape] = [.circle, .square, .triangle, .diamond, .plus, .cross, .pentagon, .asterisk]

    var body: some View {
        Chart {
            ForEach(points) { point in
                if let cost = point.row.costPerTurn {
                    let label = labels[point.row.id] ?? point.row.model
                    if resolution == .average {
                        LineMark(x: .value("Time", point.timestamp), y: .value("USD / turn", cost),
                                 series: .value("Segment", point.segment))
                            .foregroundStyle(by: .value("Model / effort", label))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    PointMark(x: .value("Time", point.timestamp), y: .value("USD / turn", cost))
                        .foregroundStyle(by: .value("Model / effort", label))
                        .symbol(by: .value("Model / effort", label))
                        .symbolSize(resolution == .turns ? 18 : point.row.turns < 5 ? 22 : point.row.turns < 30 ? 42 : 68)
                        .opacity(resolution == .turns ? 0.5 : 1)
                        .accessibilityLabel("\(label), \(Format.dateTime(point.start))")
                        .accessibilityValue("\(String(format: "$%.4f", cost)) per turn, \(point.row.turns) turns")
                }
            }
        }
        .chartForegroundStyleScale(domain: legend, range: colors)
        .chartSymbolScale(domain: legend, range: legend.indices.map { Self.symbols[$0 % Self.symbols.count] })
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ceiling)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.divider)
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(String(format: ceiling < 0.02 ? "$%.3f" : "$%.2f", cost))
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary).monospacedDigit()
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
                            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
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
