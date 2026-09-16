import SwiftUI

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
        case .turns: return "Most turns"
        case .tokens: return "Fewest tokens / turn"
        case .cost: return "Lowest $ / turn"
        }
    }
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

    /// Everything the page shows, computed in one pass over the turns per render.
    private struct Derived {
        var providerTurns: [AnalysisTurn] = []
        var turns: [AnalysisTurn] = []
        var models: [AnalysisTurn] = []
        var rates: [String: ModelRates] = [:]
        var rows: [AnalysisRow] = []
        var priceSources: [String: PriceSource] = [:]
        var totalTokens = 0
        var pricedTurnCount = 0
        var pricedCost = 0.0
        var plot = AnalysisCostPlot(points: [], omittedTurns: 0, isHourly: false)
        var unpricedModels: [AnalysisTurn] { models.filter { priceSources[$0.modelKey] == .missing } }
    }

    private func derive() -> Derived {
        var d = Derived()
        let start = start, end = end, enabled = enabled
        d.providerTurns = (state.result?.turns ?? []).filter { $0.timestamp >= start && $0.timestamp <= end && enabled.contains($0.provider) }
        d.turns = selectedModel == nil ? d.providerTurns : d.providerTurns.filter { $0.modelKey == selectedModel }
        let byModel = Dictionary(grouping: d.providerTurns, by: \.modelKey)
        d.models = byModel.values.compactMap(\.first).sorted { $0.modelKey < $1.modelKey }
        d.rates = UsageAnalysis.resolvedRates(for: d.models, overrides: state.rates, catalog: prices.catalog)
        let rows = UsageAnalysis.rows(d.turns, since: start, until: end, enabled: enabled, rates: d.rates)
        switch sort {
        case .turns: d.rows = rows.sorted { $0.turns > $1.turns }
        case .tokens: d.rows = rows.sorted { $0.tokensPerTurn < $1.tokensPerTurn }
        case .cost: d.rows = rows.sorted { ($0.costPerTurn ?? .infinity, $0.turns) < ($1.costPerTurn ?? .infinity, $1.turns) }
        }
        for model in d.models {
            let priced = byModel[model.modelKey]!.allSatisfy { d.rates[$0.modelKey]?.cost($0) != nil }
            d.priceSources[model.modelKey] = UsageAnalysis.priceSource(model: model.model, key: model.modelKey, overrides: state.rates,
                                                                       catalog: prices.catalog, pricedAllTurns: priced)
        }
        for turn in d.turns {
            d.totalTokens += turn.tokens
            if let cost = d.rates[turn.modelKey]?.cost(turn) { d.pricedTurnCount += 1; d.pricedCost += cost }
        }
        d.plot = AnalysisCostPlot.make(d.turns, since: start, until: end, enabled: enabled, rates: d.rates, resolution: plotResolution)
        return d
    }

    var body: some View {
        let d = derive()
        return VStack(alignment: .leading, spacing: 16) {
            header
            toolbar(d)
            if let result = state.result, result.unreadableFiles > 0 {
                Label("\(result.unreadableFiles) log files could not be read. Results cover the accessible logs.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Theme.caution)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if d.rows.isEmpty {
                        emptyState
                    } else {
                        summaryTiles(d)
                        UsageCostChart(plot: d.plot, start: start, end: end, resolution: $plotResolution,
                                       onFixPrices: { withAnimation { showRates = true } })
                        findings(d)
                        modelTable(d)
                        subscriptionTable(d)
                        pricingCard(d)
                    }
                    Text("A turn is one recorded model response, including tool-use responses; streaming duplicates and repeated Codex counters are removed. This is an observational comparison across different tasks: it cannot infer task success, retries or cost per completed task. Claude effort appears only when recorded. Cursor keeps no supported local turn history.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .background(Theme.bg).foregroundStyle(Theme.textPrimary).preferredColorScheme(.dark)
        .onChange(of: selectedProvider) { _, _ in selectedModel = nil }
        .onChange(of: days) { _, _ in if let selectedModel, !derive().models.contains(where: { $0.modelKey == selectedModel }) { self.selectedModel = nil } }
        .task {
            if state.result == nil && !RenderFlags.isRendering { await state.analyze() }
            await prices.refreshIfStale()
        }
    }

    // MARK: Header & controls

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage & effort").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Cost and token use per assistant turn, from your local session logs").foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if state.isScanning { ProgressView().controlSize(.small).padding(.trailing, 6) }
            Button { Task { await state.analyze() } } label: {
                Label(state.isScanning ? "Analyzing…" : "Rescan logs", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ChipButtonStyle()).disabled(state.isScanning)
        }
    }

    private func toolbar(_ d: Derived) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Picker("Range", selection: $days) {
                    Text("24h").tag(1)
                    Text("7d").tag(7)
                    Text("30d").tag(30)
                    Text("90d").tag(90)
                    if !Self.presets.contains(days) { Text("\(days)d").tag(days) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: Self.presets.contains(days) ? 220 : 270)
                Stepper("Days", value: $days, in: 1...120).labelsHidden().help("Custom range: 1–120 days")
            }
            Picker("Provider", selection: $selectedProvider) {
                Text("All providers").tag(nil as ProviderID?)
                ForEach(settings.orderedEnabledProviders) { Text($0.displayName).tag(Optional($0)) }
            }.labelsHidden().frame(width: 150)
            Picker("Model", selection: $selectedModel) {
                Text("All models").tag(nil as String?)
                ForEach(d.models) { Text("\($0.provider.displayName) · \($0.model)").tag(Optional($0.modelKey)) }
            }.labelsHidden().frame(maxWidth: 320)
            Spacer()
            Text("\(Format.dateTime(start)) – \(Format.dateTime(end))")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).monospacedDigit()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: state.isScanning ? "doc.text.magnifyingglass" : "tray")
                .font(.system(size: 28)).foregroundStyle(Theme.textMuted)
            Text(state.isScanning ? "Reading local session usage…" : "No recorded assistant turns in this range")
                .font(.headline)
            if !state.isScanning {
                Text("Try a longer range, pick another provider, or enable a provider in Settings.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Summary

    private func summaryTiles(_ d: Derived) -> some View {
        let priced = d.pricedTurnCount, total = d.pricedCost, count = d.turns.count
        let coverage = count == 0 ? 0 : Double(priced) / Double(count)
        let complete = priced == count
        return HStack(spacing: 12) {
            StatTile(value: "\(count)", label: "turns · \(days == 1 ? "24 hours" : "\(days) days")")
            StatTile(value: Format.tokens(d.totalTokens), label: "tokens · \(Format.tokens(d.totalTokens / max(1, count))) per turn")
            StatTile(value: priced == 0 ? "—" : (complete ? "" : "≥ ") + money(total, 2),
                     label: complete ? "est. API cost at list prices" : "est. API cost · \(Int(coverage * 100))% of turns priced",
                     tint: complete || priced == 0 ? Theme.textPrimary : Theme.caution)
            StatTile(value: priced == 0 ? "—" : money(total / Double(priced), 4),
                     label: complete ? "est. API $ per turn" : "est. $ per priced turn")
        }
    }

    private func findings(_ d: Derived) -> some View {
        let rows = d.rows, unpricedModels = d.unpricedModels
        return VStack(alignment: .leading, spacing: 8) {
            Text("What the logs show").font(.headline)
            if let best = UsageAnalysis.cheapest(rows) {
                finding("dollarsign.circle", "Lowest estimated API cost per turn: **\(best.model) · \(best.effort ?? "effort not recorded")** at \(money(best.costPerTurn, 4)).")
            } else if !unpricedModels.isEmpty {
                finding("exclamationmark.circle", "A cost comparison needs a price for every model. \(unpricedModels.count == 1 ? "1 model has" : "\(unpricedModels.count) models have") no price: \(unpricedModels.map(\.model).joined(separator: ", ")).")
            } else {
                finding("exclamationmark.circle", "A cost comparison needs at least 5 turns in every compared group.")
            }
            if rows.count >= 2, let lowest = rows.filter({ $0.turns >= 5 }).min(by: { $0.tokensPerTurn < $1.tokensPerTurn }) {
                finding("text.word.spacing", "Lowest token use per turn: **\(lowest.model) · \(lowest.effort ?? "effort not recorded")** at \(Format.tokens(Int(lowest.tokensPerTurn))) tokens.")
            }
            Text("Cheaper turns are not the same as cheaper tasks: a higher effort level may finish the same work in fewer turns.")
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func finding(_ icon: String, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 16)
            Text(try! AttributedString(markdown: markdown))
        }
    }

    // MARK: Table

    private func modelTable(_ d: Derived) -> some View {
        let rows = d.rows
        let total = rows.reduce(0) { $0 + $1.turns }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model & reasoning effort").font(.headline)
                Spacer()
                Picker("Sort", selection: $sort) { ForEach(AnalysisRowSort.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 190)
            }
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    Text("Model / effort").gridColumnAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Turns")
                    Text("Tokens / turn")
                    Text("Est. $ / turn")
                    Text("Est. total")
                    Text("Pricing").gridColumnAlignment(.leading)
                }
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).padding(.bottom, 8)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows) { row in
                    GridRow {
                        HStack(spacing: 8) {
                            ProviderDot(id: row.provider, size: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.model).fontWeight(.medium).lineLimit(1)
                                Text("\(row.provider.displayName) · \(row.effort ?? "effort not recorded")")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(row.turns)").foregroundStyle(row.turns < 5 ? Theme.caution : Theme.textPrimary)
                            Text(total > 0 ? "\(Int((Double(row.turns) / Double(total) * 100).rounded()))%" : "")
                                .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        }
                        Text(Format.tokens(Int(row.tokensPerTurn)))
                        Text(money(row.costPerTurn, 4)).foregroundStyle(row.costPerTurn == nil ? Theme.textMuted : Theme.textPrimary)
                        Text(money(row.cost, 2)).foregroundStyle(row.cost == nil ? Theme.textMuted : Theme.textPrimary)
                        priceBadge(d.priceSources[row.provider.rawValue + "/" + row.model] ?? .missing).gridColumnAlignment(.leading)
                    }
                    .padding(.vertical, 8)
                    Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5)
                }
            }
            .font(.system(size: 12)).monospacedDigit()
            Text("Yellow turn counts have fewer than 5 observations. Estimates apply one rate per model across the whole range; they are not your subscription bill.")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
        .padding(16).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func priceBadge(_ source: PriceSource) -> some View {
        Group {
            switch source {
            case .listed(let name):
                Badge(text: "LiteLLM", color: Theme.ok).help("List price from LiteLLM entry “\(name)”")
            case .custom:
                Badge(text: "Custom", color: Theme.accent).help("Uses one or more rates you entered")
            case .missing:
                Button { withAnimation { showRates = true } } label: { Badge(text: "Add price", color: Theme.caution) }
                    .buttonStyle(.plain).help("No list price matched this model. Enter rates in Pricing.")
            }
        }
    }

    private func subscriptionTable(_ d: Derived) -> some View {
        let counts = Dictionary(grouping: d.providerTurns, by: \.provider).mapValues(\.count)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Subscription value").font(.headline)
            ForEach(settings.orderedEnabledProviders.filter { enabled.contains($0) }) { provider in
                let count = counts[provider] ?? 0
                let cost = UsageAnalysis.subscriptionCostPerTurn(monthly: state.monthlyCosts[provider.rawValue], days: Double(days), turns: count)
                HStack {
                    ProviderDot(id: provider, size: 8)
                    Text(provider.displayName).frame(width: 100, alignment: .leading)
                    Text("\(count) recorded turns").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if let cost {
                        Text("\(money(cost, 4)) / turn").monospacedDigit()
                    } else if count == 0 {
                        Text("No recorded turns").foregroundStyle(Theme.textMuted)
                    } else {
                        Button("Add monthly price") { withAnimation { showRates = true } }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent)
                    }
                }.font(.system(size: 12))
            }
            Text("Monthly price × selected days ÷ 30 ÷ recorded turns, across all models. This spreads a fixed bill over observed use; it is not a marginal token price, and incomplete local history inflates it.")
                .font(.caption).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Pricing

    private func pricingCard(_ d: Derived) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { showRates.toggle() } } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(showRates ? 90 : 0))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    Text("Pricing").font(.headline)
                    Text(pricingSummary(d)).font(.system(size: 12)).foregroundStyle(d.unpricedModels.isEmpty ? Theme.textSecondary : Theme.caution)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRates { costEditor(d).padding(.top, 14) }
        }
        .padding(16).background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pricingSummary(_ d: Derived) -> String {
        let models = d.models, unpricedModels = d.unpricedModels
        let listed = models.count - unpricedModels.count
        let missing = unpricedModels.isEmpty ? "" : " · \(unpricedModels.count) without a price"
        return "\(listed) of \(models.count) models priced\(missing) · LiteLLM list from \(prices.catalog.updated.formatted(date: .abbreviated, time: .omitted))"
    }

    private func costEditor(_ d: Derived) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("USD per 1 million tokens. Grey values are LiteLLM list prices; type over one to override it, or leave blank to keep the list price. Models without a list price stay unpriced until you enter rates; zero means free.")
                        .font(.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let error = prices.lastError {
                        Text("Refresh failed: \(error)").font(.caption).foregroundStyle(Theme.caution)
                    }
                }
                Spacer()
                Button { Task { await prices.refresh() } } label: {
                    Label(prices.isRefreshing ? "Refreshing…" : "Refresh list prices", systemImage: "arrow.down.circle")
                }
                .buttonStyle(ChipButtonStyle()).disabled(prices.isRefreshing)
                .help("Downloads the current price list from LiteLLM on GitHub (\(prices.catalog.models.count) models)")
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Model").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input"); Text("Cached"); Text("Cache write"); Text("Output"); Text("Source"); Text("")
                }
                .font(.caption).foregroundStyle(Theme.textMuted)
                ForEach(d.models) { model in
                    let listed = prices.catalog.match(model.model)
                    let override = state.rates[model.modelKey]
                    let hasOverride = [override?.input, override?.cached, override?.cacheWrite, override?.output].contains { $0 != nil }
                    GridRow {
                        HStack(spacing: 6) {
                            ProviderDot(id: model.provider, size: 6)
                            Text(model.model).font(.system(size: 11)).lineLimit(1)
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
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .opacity(hasOverride ? 1 : 0).disabled(!hasOverride).help("Discard your overrides for this model")
                    }
                }
            }
            Divider()
            Text("Monthly subscription prices (USD) · used for Subscription value").font(.subheadline)
            HStack(spacing: 18) {
                ForEach(settings.orderedEnabledProviders) { provider in
                    HStack(spacing: 6) {
                        ProviderDot(id: provider, size: 6)
                        Text(provider.displayName).font(.system(size: 12))
                        OptionalCostField(value: Binding(get: { state.monthlyCosts[provider.rawValue] }, set: { state.monthlyCosts[provider.rawValue] = $0 }), placeholder: "—")
                            .textFieldStyle(.roundedBorder).frame(width: 74)
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
        .textFieldStyle(.roundedBorder).frame(width: 78)
    }


    private func money(_ value: Double?, _ digits: Int) -> String { value.map { String(format: "$%.\(digits)f", $0) } ?? "—" }
    static func trim(_ value: Double) -> String {
        let s = String(format: "%.4f", value)
        var t = Substring(s)
        while t.hasSuffix("0") { t = t.dropLast() }
        if t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }
}

/// Preserve the text while editing decimal rates; commit when focus leaves or Return is pressed.
private struct OptionalCostField: View {
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
            .help(invalid ? "Enter a nonnegative USD amount, or leave blank." : "USD per 1M tokens; blank keeps the list price")
    }
    private func commit() {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { value = nil; invalid = false }
        else if let number = Double(raw), number.isFinite, number >= 0 { value = number; invalid = false }
        else { invalid = true }
    }
}
