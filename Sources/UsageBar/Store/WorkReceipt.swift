import Foundation

/// A calendar day, week or month to summarize.
struct WorkRange: Equatable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case day = "Day", week = "Week", month = "Month"
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self {
            case .day: return .day
            case .week: return .weekOfYear
            case .month: return .month
            }
        }
    }

    var kind: Kind
    var interval: DateInterval

    init(_ kind: Kind, containing date: Date, calendar: Calendar = .current) {
        self.kind = kind
        interval = calendar.dateInterval(of: kind.component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86400)
    }

    static func today(_ kind: Kind = .day) -> WorkRange { WorkRange(kind, containing: Date()) }

    func shifted(by n: Int, calendar: Calendar = .current) -> WorkRange {
        WorkRange(kind, containing: calendar.date(byAdding: kind.component, value: n, to: interval.start) ?? interval.start, calendar: calendar)
    }

    func contains(_ date: Date) -> Bool { date >= interval.start && date < interval.end }

    var dayKeys: [String] {
        var out: [String] = [], day = interval.start
        let calendar = Calendar.current
        while day < interval.end {
            out.append(Format.dayKey(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    var title: String {
        switch kind {
        case .day: return Self.format("EEE d MMM yyyy", interval.start)
        case .week:
            let last = interval.end.addingTimeInterval(-1)
            return Self.format("d MMM", interval.start) + " – " + Self.format("d MMM yyyy", last)
        case .month: return Self.format("MMMM yyyy", interval.start)
        }
    }

    /// "Today", "Yesterday", "This week" or the plain title.
    func relativeTitle(now: Date = Date()) -> String {
        let current = WorkRange(kind, containing: now)
        if self == current { return kind == .day ? "Today" : "This \(kind.rawValue.lowercased())" }
        if self == current.shifted(by: -1) { return kind == .day ? "Yesterday" : "Last \(kind.rawValue.lowercased())" }
        return title
    }

    var fileStem: String {
        switch kind {
        case .day: return "work-log-" + Format.dayKey(interval.start)
        case .week: return "work-log-week-" + Format.dayKey(interval.start)
        case .month: return "work-log-" + Self.format("yyyy-MM", interval.start)
        }
    }

    static func format(_ pattern: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

struct WorkFile: Hashable, Sendable {
    var path: String
    var edits: Int
    var name: String { (path as NSString).lastPathComponent }
}

/// What one or more sessions did in a range, ready to show or export.
struct WorkReceipt: Sendable {
    struct Session: Identifiable, Sendable {
        var id: String
        var provider: ProviderID
        var project: String
        var title: String?
        var branch: String?
        var model: String?
        var minutes: [Int]
        var activeMinutes: Int
        var files: [WorkFile]
        var tokens: Int
        var cost: Double?
        var hasUnpricedUsage: Bool
        var dayKeys: [String]
        var perDay: [String: Int]
        var start: Date { Date(timeIntervalSince1970: Double(minutes.first ?? 0) * 60) }
        var end: Date { Date(timeIntervalSince1970: Double((minutes.last ?? 0) + 1) * 60) }
        /// The agent's own title, else the files it changed.
        var name: String {
            if let title { return title }
            if !files.isEmpty { return "Edited " + WorkReceipt.fileList(files, limit: 2) }
            return "\(provider.displayName) session"
        }
    }

    struct Project: Identifiable, Sendable {
        var id: String
        var name: String
        var sessions: [Session]
        var activeMinutes: Int
        var files: [WorkFile]
        var tokens: Int
        var cost: Double?
        var hasUnpricedUsage: Bool
        var providers: [ProviderID]
        var branches: [String]
        var displayPath: String { id.hasPrefix(Files.home + "/") ? "~" + id.dropFirst(Files.home.count) : id }
    }

    struct Day: Identifiable, Sendable {
        var id: String
        var date: Date
        var activeMinutes: Int
        var projects: [String]
    }

    var range: WorkRange
    var projects: [Project]
    var days: [Day]
    var activeMinutes: Int
    var tokens: Int
    var cost: Double?
    var hasUnpricedUsage: Bool
    var hiddenProjects: [String]
    var idleMinutes: Int

    var sessionCount: Int { projects.reduce(0) { $0 + $1.sessions.count } }
    var fileCount: Int { Set(projects.flatMap { p in p.files.map { p.id + "/" + $0.path } }).count }
    var isEmpty: Bool { projects.isEmpty }

    typealias Pricer = (ProviderID, String, WorkUsage) -> Double?

    static func build(_ sessions: [WorkSession], range: WorkRange, hidden: Set<String> = [], idleMinutes: Int = 15,
                      price: Pricer = { _, _, _ in nil }) -> WorkReceipt {
        let keys = Set(range.dayKeys)
        var hiddenSeen = Set<String>()
        var entries: [Session] = []
        for s in sessions {
            let days = s.days.filter { keys.contains($0.key) }
            guard !days.isEmpty else { continue }
            guard !hidden.contains(s.project) else { hiddenSeen.insert(s.project); continue }
            var minutes = Set<Int>(), files: [String: Int] = [:], usage: [String: WorkUsage] = [:], perDay: [String: Int] = [:]
            for (day, work) in days {
                minutes.formUnion(work.minutes)
                files.merge(work.files, uniquingKeysWith: +)
                for (model, u) in work.usage { usage[model, default: WorkUsage()].add(u) }
                perDay[day] = activeMinutes(work.minutes, idle: idleMinutes)
            }
            let sorted = minutes.sorted()
            let costs = usage.map { price(s.provider, $0.key, $0.value) }
            let model = usage.max { $0.value.turns < $1.value.turns }?.key
            entries.append(Session(
                id: s.id, provider: s.provider, project: s.project, title: s.title, branch: s.branch,
                model: model.map(prettyModel), minutes: sorted, activeMinutes: activeMinutes(sorted, idle: idleMinutes),
                files: sortedFiles(files), tokens: usage.values.reduce(0) { $0 + $1.tokens },
                cost: costs.isEmpty ? nil : costs.compactMap { $0 }.reduce(0, +),
                hasUnpricedUsage: costs.contains { $0 == nil }, dayKeys: days.keys.sorted(), perDay: perDay))
        }
        return assemble(entries, range: range, idleMinutes: idleMinutes, hidden: Array(hiddenSeen))
    }

    /// Recomputes projects, days and totals from a set of sessions. Overlapping sessions are counted once.
    static func assemble(_ sessions: [Session], range: WorkRange, idleMinutes: Int, hidden: [String] = []) -> WorkReceipt {
        let grouped = Dictionary(grouping: sessions, by: \.project)
        let projects: [Project] = grouped.map { root, group in
            var files: [String: Int] = [:]
            for s in group { for f in s.files { files[f.path, default: 0] += f.edits } }
            let minutes = Array(Set(group.flatMap(\.minutes))).sorted()
            let priced = group.compactMap(\.cost)
            return Project(
                id: root, name: (root as NSString).lastPathComponent,
                sessions: group.sorted { ($0.start, $0.id) < ($1.start, $1.id) }, activeMinutes: activeMinutes(minutes, idle: idleMinutes),
                files: sortedFiles(files), tokens: group.reduce(0) { $0 + $1.tokens },
                cost: priced.isEmpty ? nil : priced.reduce(0, +), hasUnpricedUsage: group.contains(where: \.hasUnpricedUsage),
                providers: ProviderID.allCases.filter { id in group.contains { $0.provider == id } },
                branches: Array(Set(group.compactMap(\.branch))).sorted())
        }.sorted { ($0.activeMinutes, $0.tokens, $1.name) > ($1.activeMinutes, $1.tokens, $0.name) }

        let all = Array(Set(sessions.flatMap(\.minutes))).sorted()
        var days: [Day] = []
        if range.kind != .day {
            for key in range.dayKeys {
                let today = sessions.filter { $0.perDay[key] != nil }
                guard !today.isEmpty, let date = Format.day(from: key) else { continue }
                let bounds = (Int(date.timeIntervalSince1970 / 60), Int(date.addingTimeInterval(86400).timeIntervalSince1970 / 60))
                let minutes = Array(Set(today.flatMap { $0.minutes.filter { $0 >= bounds.0 && $0 < bounds.1 } })).sorted()
                var byProject: [String: Int] = [:]
                for s in today { byProject[s.project, default: 0] += s.perDay[key] ?? 0 }
                days.append(Day(id: key, date: date, activeMinutes: activeMinutes(minutes, idle: idleMinutes),
                                projects: byProject.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key as NSString).lastPathComponent }))
            }
        }
        let priced = projects.compactMap(\.cost)
        return WorkReceipt(range: range, projects: projects, days: days, activeMinutes: activeMinutes(all, idle: idleMinutes),
                           tokens: projects.reduce(0) { $0 + $1.tokens }, cost: priced.isEmpty ? nil : priced.reduce(0, +),
                           hasUnpricedUsage: projects.contains(where: \.hasUnpricedUsage), hiddenProjects: hidden.sorted(),
                           idleMinutes: idleMinutes)
    }

    func only(project: Project) -> WorkReceipt {
        Self.assemble(project.sessions, range: range, idleMinutes: idleMinutes)
    }

    func only(session: Session) -> WorkReceipt {
        Self.assemble([session], range: range, idleMinutes: idleMinutes)
    }

    /// The receipt with these projects taken off and its totals recomputed.
    func without(projects ids: Set<String>) -> WorkReceipt {
        guard projects.contains(where: { ids.contains($0.id) }) else { return self }
        return Self.assemble(projects.filter { !ids.contains($0.id) }.flatMap(\.sessions), range: range,
                             idleMinutes: idleMinutes, hidden: hiddenProjects)
    }

    /// Consecutive activity closer than the idle gap counts as continuous; isolated minutes count once.
    static func activeMinutes(_ sorted: [Int], idle: Int) -> Int {
        guard var previous = sorted.first else { return 0 }
        var total = 1
        for minute in sorted.dropFirst() {
            let gap = minute - previous
            total += gap <= idle ? gap : 1
            previous = minute
        }
        return total
    }

    static func sortedFiles(_ files: [String: Int]) -> [WorkFile] {
        files.map { WorkFile(path: $0.key, edits: $0.value) }.sorted { ($0.edits, $1.path) > ($1.edits, $0.path) }
    }

    /// "A.swift, B.swift +3 more", listing each file name once.
    static func fileList(_ files: [WorkFile], limit: Int) -> String {
        var seen = Set<String>()
        let names = files.map(\.name).filter { seen.insert($0).inserted }
        let shown = names.prefix(limit).joined(separator: ", ")
        return names.count > limit ? shown + " +\(names.count - limit) more" : shown
    }

    /// "10:02–12:07", or with weekdays for multi-day ranges; sessions that cross midnight show both days.
    static func span(_ s: Session, multiDay: Bool) -> String {
        let last = s.end.addingTimeInterval(-1)
        if !Calendar.current.isDate(s.start, inSameDayAs: last) {
            return WorkRange.format("EEE HH:mm", s.start) + " – " + WorkRange.format("EEE HH:mm", s.end)
        }
        return (multiDay ? WorkRange.format("EEE ", s.start) : "") + Format.hourMinute(s.start) + "–" + Format.hourMinute(s.end)
    }

    static func prettyModel(_ value: String) -> String {
        var model = value.replacingOccurrences(of: "claude-", with: "")
        if let range = model.range(of: #"-\d{8}$"#, options: .regularExpression) { model.removeSubrange(range) }
        return model
    }

    /// Prices usage from the saved overrides and LiteLLM list; OpenCode's recorded cost wins when present.
    static func pricer(catalog: ModelPriceCatalog, overrides: [String: ModelRates]) -> Pricer {
        final class Box: @unchecked Sendable { var rates: [String: ModelRates] = [:] }
        let box = Box()
        return { provider, model, usage in
            if let recorded = usage.recordedCost, recorded > 0 { return recorded }
            let turn = AnalysisTurn(id: "", provider: provider, timestamp: Date(), model: model, effort: nil,
                                    input: usage.input, cached: usage.cached, cacheWrite: usage.cacheWrite, output: usage.output)
            if box.rates[turn.modelKey] == nil {
                box.rates[turn.modelKey] = UsageAnalysis.resolvedRates(for: [turn], overrides: overrides, catalog: catalog)[turn.modelKey]
            }
            return box.rates[turn.modelKey]?.cost(turn)
        }
    }
}

extension Format {
    /// 252 → "4h 12m", 35 → "35m", 0 → "0m".
    static func hm(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(String(format: "%02d", m))m"
    }

    static func hourMinute(_ date: Date) -> String { WorkRange.format("HH:mm", date) }

    static func usd(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }
}
