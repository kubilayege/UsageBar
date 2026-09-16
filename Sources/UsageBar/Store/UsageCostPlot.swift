import Foundation

enum AnalysisCostResolution: String, CaseIterable, Identifiable {
    case average, turns
    var id: String { rawValue }
}

struct AnalysisCostPoint: Identifiable, Equatable {
    var id: String
    var timestamp: Date
    var start: Date
    var end: Date
    var row: AnalysisRow
    // Separate line segments avoid implying observations across empty or unpriced periods.
    var segment: String
}

struct AnalysisCostPlot {
    var points: [AnalysisCostPoint]
    var omittedTurns: Int
    var isHourly: Bool

    static func make(_ turns: [AnalysisTurn], since: Date, until: Date, enabled: Set<ProviderID>,
                     rates: [String: ModelRates], resolution: AnalysisCostResolution,
                     calendar: Calendar = .current) -> AnalysisCostPlot {
        let eligible = turns.filter { $0.timestamp >= since && $0.timestamp <= until && enabled.contains($0.provider) }
        let hourly = until.timeIntervalSince(since) <= 86400
        let component: Calendar.Component = hourly ? .hour : .day
        let series = Dictionary(grouping: eligible) { $0.modelKey + "/" + ($0.effort ?? "unknown") }
        var points: [AnalysisCostPoint] = []
        var omitted = 0
        for (key, group) in series {
            if resolution == .turns {
                for turn in group {
                    let row = UsageAnalysis.aggregate([turn], rates: rates)
                    guard row.costPerTurn != nil else { omitted += 1; continue }
                    points.append(AnalysisCostPoint(id: turn.id, timestamp: turn.timestamp, start: turn.timestamp,
                                                    end: turn.timestamp, row: row, segment: key))
                }
                continue
            }
            let buckets = Dictionary(grouping: group) { calendar.dateInterval(of: component, for: $0.timestamp)!.start }
            var previousEnd: Date?
            var segment = 0
            for bucketStart in buckets.keys.sorted() {
                let bucketEnd = calendar.dateInterval(of: component, for: bucketStart)!.end
                let row = UsageAnalysis.aggregate(buckets[bucketStart]!, rates: rates)
                guard row.costPerTurn != nil else {
                    omitted += row.turns
                    previousEnd = nil
                    continue
                }
                if previousEnd != bucketStart { segment += 1 }
                let start = max(since, bucketStart), end = min(until, bucketEnd)
                points.append(AnalysisCostPoint(id: key + "/" + String(bucketStart.timeIntervalSince1970),
                    timestamp: start.addingTimeInterval(end.timeIntervalSince(start) / 2), start: start, end: end,
                    row: row, segment: key + "/" + String(segment)))
                previousEnd = bucketEnd
            }
        }
        points.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
        return AnalysisCostPlot(points: points, omittedTurns: omitted, isHourly: hourly)
    }
}
