import SwiftUI
import Charts

@MainActor
final class UsageAnalysisState: ObservableObject {
    static let shared = UsageAnalysisState()
    @Published private(set) var result: UsageAnalysisScanner.ScanResult?
    @Published private(set) var isScanning = false
    /// Saved per-model overrides. Blank fields fall back to the LiteLLM list price.
    @Published var rates: [String: ModelRates] { didSet { save(rates, key: "analysisModelRates") } }
    @Published var monthlyCosts: [String: Double] { didSet { save(monthlyCosts, key: "analysisMonthlyCosts") } }
    /// `--render-analysis --analysis-show-prices` opens the pricing editor in the snapshot.
    var previewShowPrices = false
    /// Last derivation, kept so returning to the tab does not start from a skeleton again.
    var cachedDerivation: (key: AnalysisDerivation.Key, value: AnalysisDerived)?

    private init() {
        let defaults = RenderFlags.isRendering ? UserDefaults(suiteName: "com.kubilay.usagebar")! : .standard
        rates = defaults.data(forKey: "analysisModelRates").flatMap { try? JSONDecoder().decode([String: ModelRates].self, from: $0) } ?? [:]
        monthlyCosts = defaults.data(forKey: "analysisMonthlyCosts").flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        guard !RenderFlags.isRendering else { return }
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
    func loadLocalPreview(at date: Date) {
        guard RenderFlags.isRendering else { return }
        result = UsageAnalysisScanner.scan(now: date)
    }
    func analyze() async {
        guard !isScanning else { return }
        isScanning = true
        result = await Task.detached(priority: .utility) { UsageAnalysisScanner.scan() }.value
        isScanning = false
    }
}

enum AnalysisRowSort: String, CaseIterable, Identifiable {
    case turns, tokens, cost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .turns: return "Most used"
        case .tokens: return "Leanest"
        case .cost: return "Cheapest"
        }
    }
    var help: String {
        switch self {
        case .turns: return "Most recorded turns first"
        case .tokens: return "Fewest tokens per turn first"
        case .cost: return "Lowest estimated cost per turn first"
        }
    }
}

/// Shared visual vocabulary for reasoning effort, used by the chart, legend and table.
enum EffortStyle {
    static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static func rank(_ effort: String?) -> Int { order.firstIndex(of: effort ?? "") ?? order.count }
    static func color(_ effort: String?) -> Color {
        switch effort {
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
    static func label(_ effort: String?) -> String { effort ?? "effort not recorded" }
}

/// Colors for the four token kinds a turn is billed on.
enum TokenKindStyle {
    static let input = Theme.accent
    static let cached = Color(hex: 0x6E625B)
    static let cacheWrite = Theme.caution
    static let output = Color(hex: 0xF3ECE5)
}

struct UsageAnalysisView: View {
    @ObservedObject private var state = UsageAnalysisState.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var prices = ModelPriceStore.shared
    @State private var days = 7
    @State private var selectedProvider: ProviderID?
    @State private var selectedModel: String?
    @State private var showRates = false
    @State private var plotResolution = AnalysisCostResolution.average
    @State private var sort = AnalysisRowSort.turns

    init(days: Int = 7, provider: ProviderID? = nil, model: String? = nil,
         resolution: AnalysisCostResolution = .average) {
        _days = State(initialValue: days)
        _selectedProvider = State(initialValue: provider)
        _selectedModel = State(initialValue: model)
        _plotResolution = State(initialValue: resolution)
        _showRates = State(initialValue: UsageAnalysisState.shared.previewShowPrices)
    }

    private static let presets = [1, 7, 30, 90]
    private var enabled: Set<ProviderID> { selectedProvider.map { [$0] } ?? settings.enabledProviders }
    private var end: Date { state.result?.scannedAt ?? Date() }
    private var start: Date { end.addingTimeInterval(-Double(days) * 86400) }

    @State private var derived: AnalysisDerived?
    @State private var derivedKey: AnalysisDerivation.Key?

    private var derivationKey: AnalysisDerivation.Key {
        AnalysisDerivation.Key(scannedAt: state.result?.scannedAt, days: days, provider: selectedProvider, model: selectedModel,
                               sort: sort, resolution: plotResolution, overrides: state.rates,
                               catalogUpdated: prices.catalog.updated, enabled: settings.enabledProviders)
    }

    private func derivationInput(_ key: AnalysisDerivation.Key) -> AnalysisDerivation.Input {
        AnalysisDerivation.Input(key: key, turns: state.result?.turns ?? [], start: start, end: end, enabled: enabled, catalog: prices.catalog)
    }

    /// Runs the aggregation off the main thread so scrolling and hovering never wait on it.
    private func derive(_ key: AnalysisDerivation.Key) async {
        guard state.result != nil else { return }
        if let cached = state.cachedDerivation, cached.key == key {
            derived = cached.value; derivedKey = key
            return
        }
        let input = derivationInput(key)
        let value = await Task.detached(priority: .userInitiated) { AnalysisDerivation.compute(input) }.value
        guard !Task.isCancelled else { return }
        state.cachedDerivation = (key, value)
        derived = value
        derivedKey = key
        if let selectedModel, !value.models.contains(where: { $0.modelKey == selectedModel }) { self.selectedModel = nil }
    }

    /// Whether the visible data is behind the current controls; content dims a little while it catches up.
    private var isStale: Bool { derived != nil && derivedKey != derivationKey }

    var body: some View {
        let key = derivationKey
        let d = RenderFlags.isRendering ? AnalysisDerivation.compute(derivationInput(key)) : derived
        return VStack(alignment: .leading, spacing: 0) {
            header(d).padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 16)
            controls(d).padding(.horizontal, 28).padding(.bottom, 18)
            Rectangle().fill(Theme.divider).frame(height: 1)
            MaybeScroll {
                VStack(alignment: .leading, spacing: 18) {
                    if let result = state.result, result.unreadableFiles > 0 {
                        notice("\(result.unreadableFiles) log files could not be read. Results cover the accessible logs.")
                    }
                    if let d {
                        if d.rows.isEmpty {
                            emptyState
                        } else {
                            overview(d)
                            UsageCostChart(plot: d.plot, start: start, end: end, resolution: $plotResolution,
                                           onFixPrices: { withAnimation(.snappy) { showRates = true } })
                            highlights(d)
                            modelTable(d)
                            subscriptionCard(d)
                            pricingCard(d)
                            footnote
                        }
                    } else {
                        AnalysisSkeleton()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 28)
                .opacity(isStale ? 0.6 : 1)
                .animation(.easeOut(duration: 0.15), value: isStale)
            }
        }
        .background(Theme.bg).foregroundStyle(Theme.textPrimary).preferredColorScheme(.dark)
        .onChange(of: selectedProvider) { _, _ in selectedModel = nil }
        .task(id: key) { await derive(key) }
        .task {
            if state.result == nil && !RenderFlags.isRendering { await state.analyze() }
            await prices.refreshIfStale()
        }
    }

    // MARK: Header & controls

    private func header(_ d: AnalysisDerived?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Usage & effort").font(.system(size: 26, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    Text("\(Format.dateTime(start))  →  \(Format.dateTime(end))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    if let result = state.result {
                        Text("·").foregroundStyle(Theme.textMuted)
                        Text("scanned \(Format.relative(result.scannedAt))").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                }
            }
            Spacer()
            Button { Task { await state.analyze() } } label: {
                HStack(spacing: 7) {
                    if state.isScanning { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                    Text(state.isScanning ? "Reading logs…" : "Rescan logs").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(ChipButtonStyle()).disabled(state.isScanning)
            .help("Read Claude Code, Codex and OpenCode session logs again")
        }
    }

    private func controls(_ d: AnalysisDerived?) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(Self.presets, id: \.self) { preset in
                    segment(preset == 1 ? "24h" : "\(preset)d", selected: days == preset) { days = preset }
                }
                if !Self.presets.contains(days) { segment("\(days)d", selected: true) {} }
                Stepper("Days", value: $days, in: 1...120).labelsHidden().controlSize(.small).padding(.leading, 4)
                    .help("Custom range: 1–120 days")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chipFill))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))

            Picker("Provider", selection: $selectedProvider) {
                Text("All providers").tag(nil as ProviderID?)
                ForEach(settings.orderedEnabledProviders) { Text($0.displayName).tag(Optional($0)) }
            }.labelsHidden().frame(width: 150)
            Picker("Model", selection: $selectedModel) {
                Text("All models").tag(nil as String?)
                ForEach(d?.models ?? []) { Text("\($0.provider.displayName) · \($0.model)").tag(Optional($0.modelKey)) }
            }.labelsHidden().frame(maxWidth: 320).disabled(d == nil)
            Spacer()
        }
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.chipSelected : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? Theme.chipSelectedStroke : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(Theme.caution)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.caution.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: state.isScanning ? "doc.text.magnifyingglass" : "tray")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textMuted)
            Text(state.isScanning ? "Reading local session logs…" : "No recorded turns in this range")
                .font(.system(size: 15, weight: .semibold))
            if !state.isScanning {
                Text("Widen the range, choose another provider, or enable a provider in Settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    Button("Last 30 days") { days = 30 }.buttonStyle(ChipButtonStyle())
                    Button("Last 90 days") { days = 90 }.buttonStyle(ChipButtonStyle())
                }
                .font(.system(size: 12, weight: .medium)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 64)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    // MARK: Overview

    private func overview(_ d: AnalysisDerived) -> some View {
        let count = d.turns.count
        let priced = d.pricedTurnCount
        let coverage = count == 0 ? 0 : Double(priced) / Double(count)
        let complete = priced == count
        let providers = settings.orderedEnabledProviders.filter { (d.turnsByProvider[$0] ?? 0) > 0 }
        let perDay = Double(count) / Double(max(1, days))
        return HStack(alignment: .top, spacing: 12) {
            metric(value: count.formatted(), unit: "turns",
                   detail: days == 1 ? "in the last 24 hours" : "\(Self.compact(perDay)) per day over \(days) days",
                   segments: providers.map { (Double(d.turnsByProvider[$0] ?? 0), $0.color, $0.displayName) })
            metric(value: Format.tokens(d.totalTokens), unit: "tokens",
                   detail: "\(Format.tokens(d.totalTokens / max(1, count))) per turn · \(cacheShare(d)) of input served from cache",
                   segments: [(Double(d.input), TokenKindStyle.input, "uncached in"),
                              (Double(d.cached), TokenKindStyle.cached, "cached"),
                              (Double(d.cacheWrite), TokenKindStyle.cacheWrite, "cache write"),
                              (Double(d.output), TokenKindStyle.output, "output")])
            metric(value: priced == 0 ? "—" : (complete ? "" : "≥ ") + money(d.pricedCost, 2), unit: "est. API cost",
                   detail: priced == 0 ? "No priced turns yet"
                        : complete ? "\(money(d.pricedCost / Double(priced), 4)) per turn at list prices"
                        : "\(money(d.pricedCost / Double(priced), 4)) per priced turn · \(Int(coverage * 100))% of turns priced",
                   tint: complete || priced == 0 ? Theme.textPrimary : Theme.caution,
                   segments: providers.compactMap { p in (d.costByProvider[p] ?? 0) > 0 ? (d.costByProvider[p]!, p.color, p.displayName) : nil })
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cacheShare(_ d: AnalysisDerived) -> String {
        let input = d.input + d.cached + d.cacheWrite
        return input > 0 ? "\(Int((100 * Double(d.cached) / Double(input)).rounded()))%" : "—"
    }

    private func metric(value: String, unit: String, detail: String, tint: Color = Theme.textPrimary,
                        segments: [(Double, Color, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if value.hasPrefix("≥ ") {
                        Text("≥").font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textMuted)
                            .help("Lower bound: some turns have no price")
                    }
                    Text(value.hasPrefix("≥ ") ? String(value.dropFirst(2)) : value)
                        .font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                    Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            CompositionBar(segments: segments)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    // MARK: Highlights

    private func highlights(_ d: AnalysisDerived) -> some View {
        let rows = d.rows, unpriced = d.unpricedModels
        let total = rows.reduce(0) { $0 + $1.turns }
        let mostUsed = rows.max { $0.turns < $1.turns }
        let leanest = rows.filter { $0.turns >= 5 }.min { $0.tokensPerTurn < $1.tokensPerTurn }
        let cheapest = UsageAnalysis.cheapest(rows)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let mostUsed {
                    highlight("Most used", row: mostUsed,
                              value: total > 0 ? "\(Int((Double(mostUsed.turns) / Double(total) * 100).rounded()))%" : "—", caption: "of \(total.formatted()) turns")
                }
                if let leanest {
                    highlight("Leanest per turn", row: leanest, value: Format.tokens(Int(leanest.tokensPerTurn)), caption: "tokens per turn")
                }
                if let cheapest {
                    highlight("Cheapest per turn", row: cheapest, value: money(cheapest.costPerTurn, 4), caption: "estimated at list prices")
                } else {
                    blockedHighlight(unpriced)
                }
            }
            Text("Cheaper turns are not cheaper tasks. A higher effort level can finish the same work in fewer turns.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
    }

    private func highlight(_ title: String, row: AnalysisRow, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow(title)
            HStack(spacing: 6) {
                ProviderDot(id: row.provider, size: 7)
                Text(row.model).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                EffortPill(effort: row.effort)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 18, weight: .bold, design: .monospaced))
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    private func blockedHighlight(_ unpriced: [AnalysisTurn]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Cheapest per turn")
            if unpriced.isEmpty {
                Text("Needs at least 5 turns in every compared group.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text("Widen the range to compare costs.").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            } else {
                Text(unpriced.count == 1 ? "1 model has no price: \(unpriced[0].model)."
                     : "\(unpriced.count) models have no price: \(unpriced.map(\.model).joined(separator: ", ")).")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Button("Add prices") { withAnimation(.snappy) { showRates = true } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4])).foregroundStyle(Theme.cardStroke))
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
    }

    // MARK: Table

    private func modelTable(_ d: AnalysisDerived) -> some View {
        let rows = d.rows
        let total = rows.reduce(0) { $0 + $1.turns }
        let maxTurns = rows.map(\.turns).max() ?? 1
        let maxCost = rows.compactMap(\.costPerTurn).max() ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Model & reasoning effort").font(.system(size: 15, weight: .semibold))
                Text("\(rows.count) groups").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(AnalysisRowSort.allCases) { option in
                        segment(option.label, selected: sort == option) { withAnimation(.snappy) { sort = option } }.help(option.help)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chipFill))
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Model · effort").frame(minWidth: 200, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                    Text("Turns").frame(width: 96, alignment: .leading)
                    Text("Tokens / turn").frame(width: 84, alignment: .trailing)
                    Text("Est. $ / turn").frame(width: 92, alignment: .trailing)
                    Text("Est. total").frame(width: 72, alignment: .trailing)
                    Text("Price").frame(width: 56, alignment: .leading)
                }
                .font(.system(size: 10, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.textMuted)
                .padding(.bottom, 8).padding(.horizontal, 10)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    AnalysisTableRow(row: row, total: total, maxTurns: maxTurns, maxCost: maxCost,
                                     source: d.priceSources[row.provider.rawValue + "/" + row.model] ?? .missing,
                                     onAddPrice: { withAnimation(.snappy) { showRates = true } })
                    if index < rows.count - 1 {
                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.horizontal, 10)
                    }
                }
            }
            .padding(.horizontal, -10)
            .font(.system(size: 12, weight: .medium, design: .monospaced)).monospacedDigit()
        }
        .padding(18).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    // MARK: Subscription

    private func subscriptionCard(_ d: AnalysisDerived) -> some View {
        let counts = d.turnCountByProvider
        let providers = settings.orderedEnabledProviders.filter { enabled.contains($0) }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("What each plan costs per turn").font(.system(size: 15, weight: .semibold))
                Text("Your monthly price, prorated to the selected \(days == 1 ? "day" : "\(days) days") and divided by the turns recorded.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    let count = counts[provider] ?? 0
                    let cost = UsageAnalysis.subscriptionCostPerTurn(monthly: state.monthlyCosts[provider.rawValue], days: Double(days), turns: count)
                    HStack(spacing: 12) {
                        ProviderDot(id: provider, size: 8)
                        Text(provider.displayName).font(.system(size: 13, weight: .medium)).frame(width: 96, alignment: .leading)
                        Text(count == 0 ? "no recorded turns" : "\(count.formatted()) turns").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Text("$").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            OptionalCostField(value: monthlyBinding(provider), placeholder: "—")
                                .textFieldStyle(.roundedBorder).frame(width: 64).controlSize(.small)
                            Text("/ month").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        Group {
                            if let cost {
                                Text(money(cost, 4)).foregroundStyle(Theme.textPrimary)
                            } else {
                                Text("—").foregroundStyle(Theme.textMuted)
                            }
                        }
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).frame(width: 84, alignment: .trailing)
                        Text("/ turn").font(.system(size: 11)).foregroundStyle(Theme.textMuted).frame(width: 38, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    if index < providers.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    private func monthlyBinding(_ provider: ProviderID) -> Binding<Double?> {
        Binding(get: { state.monthlyCosts[provider.rawValue] }, set: { state.monthlyCosts[provider.rawValue] = $0 })
    }

    // MARK: Pricing

    private func pricingCard(_ d: AnalysisDerived) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { showRates.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showRates ? 90 : 0))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary).frame(width: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Token prices").font(.system(size: 15, weight: .semibold))
                        Text(pricingSummary(d)).font(.system(size: 11)).foregroundStyle(d.unpricedModels.isEmpty ? Theme.textMuted : Theme.caution)
                    }
                    Spacer()
                    if !d.unpricedModels.isEmpty && !showRates {
                        Badge(text: "\(d.unpricedModels.count) missing", color: Theme.caution)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRates { costEditor(d).padding(.top, 16) }
        }
        .padding(18).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }

    private func pricingSummary(_ d: AnalysisDerived) -> String {
        let models = d.models, unpricedModels = d.unpricedModels
        let listed = models.count - unpricedModels.count
        let missing = unpricedModels.isEmpty ? "" : " · \(unpricedModels.count) without a price"
        return "\(listed) of \(models.count) models priced\(missing) · LiteLLM list from \(prices.catalog.updated.formatted(date: .abbreviated, time: .omitted))"
    }

    private func costEditor(_ d: AnalysisDerived) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("USD per million tokens. Grey values are LiteLLM list prices. Type over one to override it, or leave it blank to keep the list price. Zero means free.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let error = prices.lastError {
                        Text("Refresh failed: \(error)").font(.system(size: 11)).foregroundStyle(Theme.caution)
                    }
                }
                Spacer()
                Button { Task { await prices.refresh() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 11, weight: .semibold))
                        Text(prices.isRefreshing ? "Refreshing…" : "Refresh list prices").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(ChipButtonStyle()).disabled(prices.isRefreshing)
                .help("Downloads the current price list from LiteLLM on GitHub (\(prices.catalog.models.count) models)")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input"); Text("Cached"); Text("Cache write"); Text("Output"); Text("Source"); Text("")
                }
                .font(.system(size: 10, weight: .semibold)).tracking(0.4).foregroundStyle(Theme.textMuted)
                ForEach(d.models) { model in
                    let listed = prices.catalog.match(model.model)
                    let override = state.rates[model.modelKey]
                    let hasOverride = [override?.input, override?.cached, override?.cacheWrite, override?.output].contains { $0 != nil }
                    GridRow {
                        HStack(spacing: 6) {
                            ProviderDot(id: model.provider, size: 6)
                            Text(model.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        rateField(model.modelKey, \.input, listed: listed?.price.rates.input)
                        rateField(model.modelKey, \.cached, listed: listed?.price.rates.cached)
                        rateField(model.modelKey, \.cacheWrite, listed: listed?.price.rates.cacheWrite)
                        rateField(model.modelKey, \.output, listed: listed?.price.rates.output)
                        Group {
                            if let listed {
                                Text(hasOverride ? "Custom over \(listed.name)" : listed.name)
                            } else {
                                Text(hasOverride ? "Custom" : "No list price").foregroundStyle(hasOverride ? Theme.textSecondary : Theme.caution)
                            }
                        }
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(width: 190, alignment: .leading)
                        Button("Reset") { state.rates[model.modelKey] = nil }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                            .opacity(hasOverride ? 1 : 0).disabled(!hasOverride).help("Discard your overrides for this model")
                    }
                }
            }
        }
    }

    private func rateField(_ key: String, _ path: WritableKeyPath<ModelRates, Double?>, listed: Double?) -> some View {
        OptionalCostField(value: Binding(get: { state.rates[key]?[keyPath: path] }, set: { value in
            var rates = state.rates[key] ?? ModelRates()
            rates[keyPath: path] = value
            state.rates[key] = rates
        }), placeholder: listed.map { Self.trim($0) } ?? "Unknown")
        .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 78)
    }

    // MARK: Footnote

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow("About these numbers")
            Group {
                Text("A turn is one recorded model response, including tool-use responses. Streaming duplicates and repeated Codex counters are removed.")
                Text("Estimates apply one list rate per model across the whole range. They are not historical prices or your bill, and unknown prices are never shown as $0.")
                Text("This is an observational comparison across different tasks. It cannot infer task success, retries or cost per completed task. Claude effort appears only when recorded. Cursor keeps no supported local turn history.")
            }
            .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func money(_ value: Double?, _ digits: Int) -> String { value.map { String(format: "$%.\(digits)f", $0) } ?? "—" }
    static func trim(_ value: Double) -> String {
        let s = String(format: "%.4f", value)
        var t = Substring(s)
        while t.hasSuffix("0") { t = t.dropLast() }
        if t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }
    private static func compact(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f", value) : value >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    }
}

// MARK: - Building blocks

/// One table row. Hover state lives here so moving the mouse never re-renders the page or re-aggregates turns.
struct AnalysisTableRow: View {
    var row: AnalysisRow
    var total: Int
    var maxTurns: Int
    var maxCost: Double
    var source: PriceSource
    var onAddPrice: () -> Void
    @State private var hovered = false

    var body: some View {
        let lowSample = row.turns < 5
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ProviderDot(id: row.provider, size: 7)
                Text(row.model).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                EffortPill(effort: row.effort).fixedSize()
                if lowSample {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(Theme.caution)
                        .help("Fewer than 5 turns: too few to compare")
                }
            }.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(row.turns.formatted()).foregroundStyle(lowSample ? Theme.caution : Theme.textPrimary)
                    Text(total > 0 ? "\(Int((Double(row.turns) / Double(total) * 100).rounded()))%" : "")
                        .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
                MiniBar(fraction: Double(row.turns) / Double(max(1, maxTurns)), color: row.provider.color, width: 80)
            }
            .frame(width: 96, alignment: .leading)
            Text(Format.tokens(Int(row.tokensPerTurn))).frame(width: 84, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 5) {
                Text(money(row.costPerTurn, 4)).foregroundStyle(row.costPerTurn == nil ? Theme.textMuted : Theme.textPrimary)
                MiniBar(fraction: maxCost > 0 ? (row.costPerTurn ?? 0) / maxCost : 0, color: EffortStyle.color(row.effort), width: 56)
            }
            .frame(width: 92, alignment: .trailing)
            Text(money(row.cost, 2)).foregroundStyle(row.cost == nil ? Theme.textMuted : Theme.textSecondary).frame(width: 72, alignment: .trailing)
            priceBadge.frame(width: 56, alignment: .leading)
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? Color.white.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    @ViewBuilder private var priceBadge: some View {
        switch source {
        case .listed(let name):
            Badge(text: "List", color: Theme.ok).help("LiteLLM list price for “\(name)”")
        case .custom:
            Badge(text: "Custom", color: Theme.accent).help("Uses one or more rates you entered")
        case .missing:
            Button(action: onAddPrice) { Badge(text: "Add", color: Theme.caution) }
                .buttonStyle(.plain).help("No list price matched this model. Enter rates in Pricing.")
        }
    }

    private func money(_ value: Double?, _ digits: Int) -> String { value.map { String(format: "$%.\(digits)f", $0) } ?? "—" }
}

/// Wireframe stand-ins shown while logs are read and aggregated in the background.
struct AnalysisSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    card(height: 118) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                SkeletonBlock(width: 96, height: 26)
                                SkeletonBlock(width: 44, height: 12)
                            }
                            SkeletonBlock(width: 180, height: 10)
                            Spacer(minLength: 0)
                            SkeletonBlock(height: 6)
                            HStack(spacing: 10) {
                                SkeletonBlock(width: 60, height: 8)
                                SkeletonBlock(width: 48, height: 8)
                            }
                        }
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBlock(width: 190, height: 14)
                            SkeletonBlock(width: 300, height: 10)
                        }
                        Spacer()
                        SkeletonBlock(width: 210, height: 22)
                    }
                    SkeletonBlock(height: 240, radius: 8).opacity(0.7)
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBlock(width: 150, height: 24, radius: 8) }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    card(height: 92) {
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 80, height: 9)
                            SkeletonBlock(width: 160, height: 13)
                            SkeletonBlock(width: 110, height: 18)
                        }
                    }
                }
            }
            card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SkeletonBlock(width: 200, height: 14)
                        SkeletonBlock(width: 60, height: 12)
                        Spacer()
                        SkeletonBlock(width: 220, height: 24, radius: 8)
                    }
                    ForEach(0..<6, id: \.self) { index in
                        HStack(spacing: 12) {
                            HStack(spacing: 9) {
                                SkeletonBlock(width: 7, height: 7, radius: 4)
                                SkeletonBlock(width: CGFloat(120 + (index * 37) % 90), height: 12)
                                SkeletonBlock(width: 44, height: 14, radius: 7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SkeletonBlock(width: 80, height: 12)
                            SkeletonBlock(width: 60, height: 12)
                            SkeletonBlock(width: 56, height: 12)
                            SkeletonBlock(width: 56, height: 12)
                            SkeletonBlock(width: 36, height: 14, radius: 7)
                        }
                        .padding(.vertical, 9)
                        if index < 5 { Rectangle().fill(Theme.divider).frame(height: 1) }
                    }
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading local session logs…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityLabel("Loading usage analysis")
    }

    private func card<Content: View>(height: CGFloat? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

/// A pulsing placeholder bar. One shared phase keeps every block in step.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 4
    @State private var bright = false
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.white.opacity(bright ? 0.12 : 0.06))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .onAppear {
                guard !RenderFlags.isRendering else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}

/// Effort level as a small tinted pill, using the same colors as the chart.
struct EffortPill: View {
    var effort: String?
    var body: some View {
        let color = EffortStyle.color(effort)
        Text(EffortStyle.label(effort))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(effort == nil ? Theme.textMuted : color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(effort == nil ? 0.08 : 0.16)))
    }
}

/// A stacked proportion bar with a compact legend underneath.
struct CompositionBar: View {
    var segments: [(Double, Color, String)]
    private var total: Double { segments.reduce(0) { $0 + $1.0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if total <= 0 {
                        Capsule().fill(Theme.track)
                    } else {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            let share = segment.0 / total
                            if share > 0 {
                                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(segment.1)
                                    .frame(width: max(2, (geo.size.width - CGFloat(segments.count - 1) * 2) * share))
                            }
                        }
                    }
                }
            }
            .frame(height: 6)
            FlowLayout(spacing: 10) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.0 > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(segment.1).frame(width: 6, height: 6)
                            Text(segment.2).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                            Text(total > 0 ? "\(Int((segment.0 / total * 100).rounded()))%" : "")
                                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            }
        }
    }
}

/// Thin proportional bar used inside table cells.
struct MiniBar: View {
    var fraction: Double
    var color: Color
    var width: CGFloat = 96
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.track.opacity(0.6))
            Capsule().fill(color.opacity(0.9)).frame(width: max(fraction > 0 ? 3 : 0, width * CGFloat(min(1, max(0, fraction)))))
        }
        .frame(width: width, height: 3)
    }
}

/// Preserve the text while editing decimal rates; commit when focus leaves or Return is pressed.
struct OptionalCostField: View {
    @Binding var value: Double?
    var placeholder = "Unknown"
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .onAppear { text = value.map { UsageAnalysisView.trim($0) } ?? "" }
            .onChange(of: value) { _, newValue in if !focused { text = newValue.map { UsageAnalysisView.trim($0) } ?? "" } }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            .foregroundStyle(invalid ? Theme.caution : Theme.textPrimary)
            .help(invalid ? "Enter a nonnegative USD amount, or leave blank." : "USD amount; blank keeps the default")
    }
    private func commit() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { value = nil; invalid = false }
        else if let number = Double(raw), number.isFinite, number >= 0 { value = number; invalid = false }
        else { invalid = true }
    }
}
