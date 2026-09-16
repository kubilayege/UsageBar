import Foundation

struct AnalysisTests {
    func testRepeatedCodexCountersAndEffortChanges() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let date = "2026-09-15T12:00:00Z"
        func counter(_ input: Int, _ cached: Int, _ output: Int) -> JSON {
            let values: JSON = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "total_tokens": input + output]
            return ["type": "event_msg", "timestamp": date, "payload": ["type": "token_count", "info": ["total_token_usage": values, "last_token_usage": values]]]
        }
        let records: [JSON] = [
            ["type": "session_meta", "payload": ["id": "abc"]],
            ["type": "turn_context", "payload": ["model": "test-model", "effort": "medium"]],
            counter(100, 20, 10), counter(100, 20, 10),
            ["type": "turn_context", "payload": ["model": "test-model", "effort": "high"]],
            counter(160, 30, 40), counter(160, 30, 40),
        ]
        let data = try records.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); $0.append(10) }
        try data.write(to: path)
        let turns = UsageAnalysisScanner.parse(path.path, provider: .codex) ?? []
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.reduce(0) { $0 + $1.tokens }, 200)
        XCTAssertEqual(turns.first { $0.effort == "high" }?.tokens, 90)
        XCTAssertEqual(turns.first { $0.effort == "medium" }?.input, 80)
    }

    func testClaudeStreamingKeepsFinalUsage() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let records: [JSON] = [10, 30, 20].map { output in
            ["type": "assistant", "timestamp": "2026-09-15T12:00:00Z", "message": ["id": "same-request", "model": "claude-test", "usage": ["input_tokens": 100, "output_tokens": output]]]
        }
        try records.map { try JSONSerialization.data(withJSONObject: $0) }.reduce(into: Data()) { $0.append($1); $0.append(10) }.write(to: path)
        let turns = UsageAnalysisScanner.parse(path.path, provider: .claude) ?? []
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.tokens, 130)
        XCTAssertEqual(turns.first?.effort, nil)
    }

    func testUnknownCostsDoNotWinAndDateRangeIsExact() {
        let now = Date()
        let turn = AnalysisTurn(id: "1", provider: .codex, timestamp: now, model: "test", effort: "high", input: 1_000, cached: 2_000, cacheWrite: 0, output: 500)
        let rates = ModelRates(input: 2, cached: 0.2, output: 10)
        XCTAssertEqual(rates.cost(turn), 0.0074)
        XCTAssertEqual(ModelRates(input: 2, output: 10).cost(turn), nil)
        let rows = UsageAnalysis.rows([turn], since: now.addingTimeInterval(-10), until: now, enabled: [.codex], rates: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.cost, nil)
        XCTAssertTrue(UsageAnalysis.cheapest(rows) == nil)
        XCTAssertTrue(UsageAnalysis.rows([turn], since: now.addingTimeInterval(1), until: now.addingTimeInterval(10), enabled: [.codex], rates: [:]).isEmpty)
        XCTAssertTrue(UsageAnalysis.rows([turn], since: now.addingTimeInterval(-10), until: now, enabled: [.claude], rates: [:]).isEmpty)
        XCTAssertEqual(UsageAnalysis.subscriptionCostPerTurn(monthly: 30, days: 7, turns: 10), 0.7)
        XCTAssertEqual(UsageAnalysis.subscriptionCostPerTurn(monthly: nil, days: 7, turns: 10), nil)
    }

    func testCostPlotWeightsTurnsAndClipsRange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Format.parseISO("2026-09-10T12:00:00Z")!
        let end = start.addingTimeInterval(3 * 86400)
        let input = [(0.0, 1), (10.0, 3), (20.0, 5), (86400.0, 9), (3 * 86400.0, 12), (-1.0, 100), (3 * 86400.0 + 1, 100)]
        var turns = input.enumerated().map { i, value in
            AnalysisTurn(id: String(i), provider: .codex, timestamp: start.addingTimeInterval(value.0),
                         model: "test", effort: "medium", input: value.1, cached: 0, cacheWrite: 0, output: 0)
        }
        turns.append(AnalysisTurn(id: "disabled", provider: .claude, timestamp: start, model: "test",
                                  effort: "medium", input: 100, cached: 0, cacheWrite: 0, output: 0))
        let rates = ["codex/test": ModelRates(input: 1_000_000)]
        let plot = AnalysisCostPlot.make(turns, since: start, until: end, enabled: [.codex], rates: rates,
                                        resolution: .average, calendar: calendar)
        XCTAssertEqual(plot.isHourly, false)
        XCTAssertEqual(plot.points.count, 3)
        XCTAssertEqual(plot.points.first?.row.costPerTurn, 3)
        XCTAssertEqual(plot.points.first?.row.turns, 3)
        XCTAssertEqual(plot.points.first?.start, start)
        XCTAssertEqual(plot.points.last?.end, end)
        let table = UsageAnalysis.rows(turns, since: start, until: end, enabled: [.codex], rates: rates)
        XCTAssertEqual(plot.points.reduce(0) { $0 + $1.row.turns }, table[0].turns)
        XCTAssertEqual(plot.points.reduce(0) { $0 + ($1.row.cost ?? 0) }, table[0].cost)
        XCTAssertEqual(table[0].costPerTurn, 6) // Turn weighted, not the mean of daily means (8).
        let dots = AnalysisCostPlot.make(turns, since: start, until: end, enabled: [.codex], rates: rates,
                                        resolution: .turns, calendar: calendar)
        XCTAssertEqual(dots.points.count, 5)
        XCTAssertEqual(dots.points.map(\.timestamp), dots.points.map(\.timestamp).sorted())
        XCTAssertEqual(dots.points.last?.timestamp, end)
    }

    func testCostPlotMissingRatesAndGapsAreNotZero() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Format.parseISO("2026-09-10T00:00:00Z")!
        let turns = [
            AnalysisTurn(id: "free", provider: .codex, timestamp: start, model: "test", effort: "medium", input: 10, cached: 0, cacheWrite: 0, output: 0),
            AnalysisTurn(id: "priced", provider: .codex, timestamp: start.addingTimeInterval(86400), model: "test", effort: "medium", input: 10, cached: 0, cacheWrite: 0, output: 0),
            AnalysisTurn(id: "unknown", provider: .codex, timestamp: start.addingTimeInterval(86401), model: "test", effort: "medium", input: 10, cached: 100, cacheWrite: 0, output: 0),
            AnalysisTurn(id: "later", provider: .codex, timestamp: start.addingTimeInterval(3 * 86400), model: "test", effort: "medium", input: 10, cached: 0, cacheWrite: 0, output: 0),
        ]
        let end = start.addingTimeInterval(4 * 86400)
        let rates = ["codex/test": ModelRates(input: 0)]
        let plot = AnalysisCostPlot.make(turns, since: start, until: end, enabled: [.codex], rates: rates,
                                        resolution: .average, calendar: calendar)
        XCTAssertEqual(plot.points.count, 2)
        XCTAssertEqual(plot.omittedTurns, 2) // A partially priced period must not show a biased average.
        XCTAssertEqual(plot.points.first?.row.costPerTurn, 0)
        XCTAssertTrue(plot.points.first?.segment != plot.points.last?.segment)
        let dots = AnalysisCostPlot.make(turns, since: start, until: end, enabled: [.codex], rates: rates,
                                        resolution: .turns, calendar: calendar)
        XCTAssertEqual(dots.points.count, 3)
        XCTAssertEqual(dots.omittedTurns, 1)
        let unknown = AnalysisCostPlot.make(turns, since: start, until: end, enabled: [.codex], rates: [:],
                                           resolution: .average, calendar: calendar)
        XCTAssertTrue(unknown.points.isEmpty)
        XCTAssertEqual(unknown.omittedTurns, 4)
    }

    func testCostPlotHourlyBucketsAndSeparateEfforts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Format.parseISO("2026-09-10T12:30:00Z")!
        let turns = [(0.0, "medium"), (1800.0, "medium"), (1801.0, "xhigh"), (5400.0, "medium")].enumerated().map { i, value in
            AnalysisTurn(id: String(i), provider: .codex, timestamp: start.addingTimeInterval(value.0),
                         model: "test", effort: value.1, input: 1, cached: 0, cacheWrite: 0, output: 0)
        }
        let plot = AnalysisCostPlot.make(turns, since: start, until: start.addingTimeInterval(86400), enabled: [.codex],
                                        rates: ["codex/test": ModelRates(input: 1)], resolution: .average, calendar: calendar)
        XCTAssertEqual(plot.isHourly, true)
        XCTAssertEqual(plot.points.count, 4)
        let medium = plot.points.filter { $0.row.effort == "medium" }
        XCTAssertEqual(Set(medium.map(\.segment)).count, 1)
        XCTAssertEqual(medium.first?.end, start.addingTimeInterval(1800))
        XCTAssertEqual(Set(plot.points.map { $0.row.id }).count, 2)
    }

    func testCostPlotUsesLocalCalendarAcrossDST() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = Format.parseISO("2026-03-07T05:00:00Z")!
        let end = Format.parseISO("2026-03-10T04:00:00Z")!
        let turns = ["2026-03-07T12:00:00Z", "2026-03-08T12:00:00Z", "2026-03-09T12:00:00Z"].enumerated().map { i, date in
            AnalysisTurn(id: String(i), provider: .codex, timestamp: Format.parseISO(date)!, model: "test",
                         effort: nil, input: 1, cached: 0, cacheWrite: 0, output: 0)
        }
        let plot = AnalysisCostPlot.make(turns, since: start, until: end, enabled: [.codex],
                                        rates: ["codex/test": ModelRates(input: 1)], resolution: .average, calendar: calendar)
        XCTAssertEqual(plot.points.count, 3)
        XCTAssertEqual(plot.points[1].end.timeIntervalSince(plot.points[1].start), 23 * 3600)
        XCTAssertEqual(Set(plot.points.map(\.segment)).count, 1)
    }

    func testListPricesMatchLoggedModelNamesAndOverridesWin() {
        let catalog = ModelPriceCatalog.parse(Data("""
        {"claude-opus-4-1": {"mode": "chat", "input_cost_per_token": 15e-6, "output_cost_per_token": 75e-6, "cache_read_input_token_cost": 1.5e-6, "cache_creation_input_token_cost": 18.75e-6},
         "gpt-5-codex": {"mode": "responses", "input_cost_per_token": 1.25e-6, "output_cost_per_token": 10e-6, "cache_read_input_token_cost": 0.125e-6},
         "openrouter/vendor/kimi-k2": {"mode": "chat", "input_cost_per_token": 0.55e-6, "output_cost_per_token": 2.2e-6},
         "text-embedding-3-small": {"mode": "embedding", "input_cost_per_token": 0.02e-6, "output_cost_per_token": 0}}
        """.utf8), source: "test")!
        XCTAssertEqual(catalog.models.count, 3)
        XCTAssertEqual(catalog.match("claude-opus-4-1-20250805")?.price.input, 15)
        XCTAssertEqual(catalog.match("CLAUDE-OPUS-4-1")?.price.cacheWrite, 18.75)
        XCTAssertEqual(catalog.match("moonshot/kimi-k2")?.name, "kimi-k2")
        XCTAssertEqual(catalog.match("gpt-5-codex-2025-09-15")?.price.output, 10)
        XCTAssertTrue(catalog.match("codex-auto-review") == nil)
        XCTAssertEqual(ModelPriceCatalog.candidates("gemini-2.5-pro-preview-05-06").contains("gemini-2.5-pro"), true)
        // OpenAI publishes no cache-write price: writes cost the same as uncached input.
        XCTAssertEqual(catalog.match("gpt-5-codex")?.price.rates.cacheWrite, 1.25)
        let now = Date()
        let claude = AnalysisTurn(id: "a", provider: .claude, timestamp: now, model: "claude-opus-4-1-20250805", effort: nil, input: 1000, cached: 0, cacheWrite: 0, output: 100)
        let unknown = AnalysisTurn(id: "b", provider: .codex, timestamp: now, model: "codex-auto-review", effort: nil, input: 1000, cached: 0, cacheWrite: 0, output: 100)
        let rates = UsageAnalysis.resolvedRates(for: [claude, unknown], overrides: [claude.modelKey: ModelRates(output: 1)], catalog: catalog)
        XCTAssertEqual(rates[claude.modelKey]?.cost(claude), 0.015 + 0.0001)
        XCTAssertEqual(rates[unknown.modelKey]?.cost(unknown), nil)
        XCTAssertEqual(UsageAnalysis.priceSource(model: claude.model, key: claude.modelKey, overrides: [claude.modelKey: ModelRates(output: 1)], catalog: catalog, pricedAllTurns: true), .custom)
        XCTAssertEqual(UsageAnalysis.priceSource(model: claude.model, key: claude.modelKey, overrides: [:], catalog: catalog, pricedAllTurns: true), .listed("claude-opus-4-1"))
        XCTAssertEqual(UsageAnalysis.priceSource(model: unknown.model, key: unknown.modelKey, overrides: [:], catalog: catalog, pricedAllTurns: false), .missing)
        XCTAssertTrue(ModelPriceCatalog.bundled.models.count > 500)
        XCTAssertEqual(ModelPriceCatalog.bundled.match("claude-sonnet-4-5-20250929")?.price.output, 15)
    }
}
