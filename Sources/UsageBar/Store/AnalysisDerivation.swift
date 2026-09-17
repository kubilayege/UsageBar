import Foundation

/// Everything the Usage & effort page shows for one combination of range, filters and prices.
/// Computed off the main thread; the view only reads it.
struct AnalysisDerived: Sendable {
    var providerTurns: [AnalysisTurn] = []
    var turns: [AnalysisTurn] = []
    var models: [AnalysisTurn] = []
    var rates: [String: ModelRates] = [:]
    var rows: [AnalysisRow] = []
    var priceSources: [String: PriceSource] = [:]
    var totalTokens = 0
    var input = 0, cached = 0, cacheWrite = 0, output = 0
    var pricedTurnCount = 0
    var pricedCost = 0.0
    var turnsByProvider: [ProviderID: Int] = [:]
    var costByProvider: [ProviderID: Double] = [:]
    var turnCountByProvider: [ProviderID: Int] = [:]
    var unpricedModels: [AnalysisTurn] = []
    var plot = AnalysisCostPlot(points: [], omittedTurns: 0, isHourly: false)
}

enum AnalysisDerivation {
    /// The inputs that change the result. Equatable so the view can key its background task on them.
    struct Key: Equatable, Sendable {
        var scannedAt: Date?
        var days: Int
        var provider: ProviderID?
        var model: String?
        var sort: AnalysisRowSort
        var resolution: AnalysisCostResolution
        var overrides: [String: ModelRates]
        var catalogUpdated: Date
        var enabled: Set<ProviderID>
    }

    struct Input: Sendable {
        var key: Key
        var turns: [AnalysisTurn]
        var start: Date
        var end: Date
        var enabled: Set<ProviderID>
        var catalog: ModelPriceCatalog
    }

    static func compute(_ input: Input) -> AnalysisDerived {
        var d = AnalysisDerived()
        let start = input.start, end = input.end, enabled = input.enabled, key = input.key
        d.providerTurns = input.turns.filter { $0.timestamp >= start && $0.timestamp <= end && enabled.contains($0.provider) }
        d.turns = key.model == nil ? d.providerTurns : d.providerTurns.filter { $0.modelKey == key.model }
        let byModel = Dictionary(grouping: d.providerTurns, by: \.modelKey)
        d.models = byModel.values.compactMap(\.first).sorted { $0.modelKey < $1.modelKey }
        d.rates = UsageAnalysis.resolvedRates(for: d.models, overrides: key.overrides, catalog: input.catalog)
        let rows = UsageAnalysis.rows(d.turns, since: start, until: end, enabled: enabled, rates: d.rates)
        switch key.sort {
        case .turns: d.rows = rows.sorted { $0.turns > $1.turns }
        case .tokens: d.rows = rows.sorted { $0.tokensPerTurn < $1.tokensPerTurn }
        case .cost: d.rows = rows.sorted { ($0.costPerTurn ?? .infinity, $0.turns) < ($1.costPerTurn ?? .infinity, $1.turns) }
        }
        for model in d.models {
            let priced = byModel[model.modelKey]!.allSatisfy { d.rates[$0.modelKey]?.cost($0) != nil }
            d.priceSources[model.modelKey] = UsageAnalysis.priceSource(model: model.model, key: model.modelKey, overrides: key.overrides,
                                                                       catalog: input.catalog, pricedAllTurns: priced)
        }
        d.unpricedModels = d.models.filter { d.priceSources[$0.modelKey] == .missing }
        for turn in d.providerTurns { d.turnCountByProvider[turn.provider, default: 0] += 1 }
        for turn in d.turns {
            d.totalTokens += turn.tokens
            d.input += turn.input; d.cached += turn.cached; d.cacheWrite += turn.cacheWrite; d.output += turn.output
            d.turnsByProvider[turn.provider, default: 0] += 1
            if let cost = d.rates[turn.modelKey]?.cost(turn) {
                d.pricedTurnCount += 1; d.pricedCost += cost
                d.costByProvider[turn.provider, default: 0] += cost
            }
        }
        d.plot = AnalysisCostPlot.make(d.turns, since: start, until: end, enabled: enabled, rates: d.rates, resolution: key.resolution)
        return d
    }
}
