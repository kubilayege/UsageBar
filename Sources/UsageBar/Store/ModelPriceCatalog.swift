import Foundation
import Combine

/// Published API list prices in USD per 1 million tokens, from LiteLLM's public price list.
struct ModelPrice: Codable, Equatable {
    var input: Double
    var output: Double
    var cached: Double?
    var cacheWrite: Double?
    var provider: String?

    /// Cache writes are only priced separately by some vendors; OpenAI folds them into the input price.
    var rates: ModelRates {
        ModelRates(input: input, cached: cached ?? input, cacheWrite: cacheWrite ?? (cached == nil ? nil : input), output: output)
    }
}

struct ModelPriceCatalog: Equatable {
    var models: [String: ModelPrice]
    var updated: Date
    var source: String
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/refs/heads/main/model_prices_and_context_window.json")!

    static let bundled: ModelPriceCatalog = parse(Data(BundledModelPrices.json.utf8), source: "bundled") ?? ModelPriceCatalog(models: [:], updated: .distantPast, source: "bundled")

    /// Accepts the raw LiteLLM file or the trimmed snapshot written by scripts/update-prices.py.
    static func parse(_ data: Data, source: String, now: Date = Date()) -> ModelPriceCatalog? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? JSON else { return nil }
        let entries = root.dict("models") ?? root
        var models: [String: ModelPrice] = [:]
        for prefixed in [false, true] {
            for (key, value) in entries {
                guard key != "sample_spec", key.contains("/") == prefixed, let entry = value as? JSON,
                      root.dict("models") != nil || ["chat", "responses"].contains(entry.string("mode") ?? ""),
                      let input = entry.double("input_cost_per_token"), let output = entry.double("output_cost_per_token") else { continue }
                let name = key.split(separator: "/").last.map { String($0).lowercased() } ?? key
                guard models[name] == nil else { continue }
                models[name] = ModelPrice(input: input * 1e6, output: output * 1e6,
                                          cached: entry.double("cache_read_input_token_cost").map { $0 * 1e6 },
                                          cacheWrite: entry.double("cache_creation_input_token_cost").map { $0 * 1e6 },
                                          provider: entry.string("litellm_provider"))
            }
        }
        guard !models.isEmpty else { return nil }
        return ModelPriceCatalog(models: models, updated: Format.parseISO(root.string("updated")) ?? now, source: root.string("source") ?? source)
    }

    struct Match: Equatable { var name: String; var price: ModelPrice }

    /// Finds the list price for a model name as recorded by a coding agent, e.g. "claude-opus-4-1-20250805".
    func match(_ model: String) -> Match? {
        for candidate in Self.candidates(model) {
            if let price = models[candidate] { return Match(name: candidate, price: price) }
        }
        return nil
    }

    static func candidates(_ model: String) -> [String] {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) } // ollama-style tags
        var out = [name]
        func add(_ s: String) { if !s.isEmpty, !out.contains(s) { out.append(s) } }
        // Dated snapshots: claude-sonnet-4-5-20250929, gpt-5-2025-08-07, gemini-2.5-pro-preview-05-06
        for pattern in [#"-\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#, #"-\d{2}-\d{2}$"#, #"-v\d+(:\d+)?$"#, #"-latest$"#, #"-preview$"#] {
            for base in out where base.range(of: pattern, options: .regularExpression) != nil {
                add(base.replacingOccurrences(of: pattern, with: "", options: .regularExpression))
            }
        }
        return out
    }
}

/// Keeps a local copy of the LiteLLM price list and refreshes it at most once a week.
@MainActor
final class ModelPriceStore: ObservableObject {
    static let shared = ModelPriceStore()
    @Published private(set) var catalog: ModelPriceCatalog
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    private static var cacheURL: URL { Files.appSupport.appendingPathComponent("model-prices.json") }

    private init() {
        let cached = (try? Data(contentsOf: Self.cacheURL)).flatMap { ModelPriceCatalog.parse($0, source: "cache") }
        if let cached, cached.updated > ModelPriceCatalog.bundled.updated { catalog = cached } else { catalog = .bundled }
    }

    var isStale: Bool { Date().timeIntervalSince(catalog.updated) > 7 * 86400 }

    func refreshIfStale() async { if isStale && !RenderFlags.isRendering { await refresh() } }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await HTTP.request(ModelPriceCatalog.sourceURL)
            guard response.statusCode == 200 else { throw ProviderError(.network, "LiteLLM returned HTTP \(response.statusCode)") }
            guard var fresh = ModelPriceCatalog.parse(data, source: ModelPriceCatalog.sourceURL.absoluteString) else {
                throw ProviderError(.parse, "LiteLLM price list could not be parsed")
            }
            fresh.updated = Date()
            catalog = fresh
            lastError = nil
            let snapshot: [String: Any] = ["source": fresh.source, "updated": ISO8601DateFormatter().string(from: fresh.updated),
                "models": fresh.models.mapValues { price -> [String: Any] in
                    var entry: [String: Any] = ["input_cost_per_token": price.input / 1e6, "output_cost_per_token": price.output / 1e6]
                    if let c = price.cached { entry["cache_read_input_token_cost"] = c / 1e6 }
                    if let w = price.cacheWrite { entry["cache_creation_input_token_cost"] = w / 1e6 }
                    if let p = price.provider { entry["litellm_provider"] = p }
                    return entry
                }]
            if let data = try? JSONSerialization.data(withJSONObject: snapshot) { try? data.write(to: Self.cacheURL, options: .atomic) }
        } catch {
            lastError = (error as? ProviderError)?.message ?? error.localizedDescription
        }
    }
}

enum PriceSource: Equatable {
    case listed(String), custom, missing
    var label: String {
        switch self {
        case .listed: return "List price"
        case .custom: return "Custom"
        case .missing: return "No price"
        }
    }
}

extension UsageAnalysis {
    /// Field-by-field: a saved override wins, otherwise the LiteLLM list price. Blank stays unknown.
    static func resolvedRates(for turns: [AnalysisTurn], overrides: [String: ModelRates], catalog: ModelPriceCatalog) -> [String: ModelRates] {
        var out: [String: ModelRates] = [:]
        for turn in turns where out[turn.modelKey] == nil {
            let user = overrides[turn.modelKey], listed = catalog.match(turn.model)?.price.rates
            out[turn.modelKey] = ModelRates(input: user?.input ?? listed?.input, cached: user?.cached ?? listed?.cached,
                                            cacheWrite: user?.cacheWrite ?? listed?.cacheWrite, output: user?.output ?? listed?.output)
        }
        return out
    }

    static func priceSource(model: String, key: String, overrides: [String: ModelRates], catalog: ModelPriceCatalog, pricedAllTurns: Bool) -> PriceSource {
        let user = overrides[key]
        let hasOverride = [user?.input, user?.cached, user?.cacheWrite, user?.output].contains { $0 != nil }
        if !pricedAllTurns { return .missing }
        if hasOverride { return .custom }
        return .listed(catalog.match(model)?.name ?? model)
    }
}
