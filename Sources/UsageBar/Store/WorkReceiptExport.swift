import Foundation

enum WorkExportFormat: String, CaseIterable, Identifiable, Sendable {
    case text = "Text", markdown = "Markdown", csv = "CSV"
    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .csv: return "csv"
        }
    }
}

struct WorkExportOptions: Equatable, Sendable {
    var files = true
    var times = true
    var usage = false
}

/// Paste-ready renderings of a receipt. Plain text avoids column alignment so it reads well in any font.
enum WorkReceiptExport {
    enum Scope { case full, project, session }

    static func render(_ r: WorkReceipt, as format: WorkExportFormat, options: WorkExportOptions = .init(), scope: Scope = .full) -> String {
        switch format {
        case .text: return text(r, options, scope)
        case .markdown: return markdown(r, options, scope)
        case .csv: return csv(r)
        }
    }

    // MARK: Text

    private static func text(_ r: WorkReceipt, _ o: WorkExportOptions, _ scope: Scope) -> String {
        var lines: [String] = []
        let multiDay = r.range.kind != .day
        if scope == .full {
            lines.append("Work log · \(r.range.title)")
            lines.append(summary(r, o))
            if multiDay && !r.days.isEmpty {
                lines.append("")
                for d in r.days {
                    lines.append("\(WorkRange.format("EEE d MMM", d.date))  \(Format.hm(d.activeMinutes))  \(d.projects.joined(separator: ", "))")
                }
            }
        }
        for p in r.projects {
            if scope != .session {
                if !lines.isEmpty { lines.append("") }
                var header = "\(p.name) · \(Format.hm(p.activeMinutes))"
                if scope == .project { header += " · \(r.range.title)" }
                lines.append(header)
            }
            for s in p.sessions {
                var line = (scope == .session ? "" : "  • ") + s.name
                var meta = sessionMeta(s, o, multiDay: multiDay)
                if scope == .session { meta.insert(p.name, at: 0) }
                if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
                lines.append(line)
                if o.files && !s.files.isEmpty {
                    lines.append((scope == .session ? "  " : "    ") + WorkReceipt.fileList(s.files, limit: 6))
                }
            }
        }
        if r.isEmpty { lines.append(scope == .full ? "No agent activity." : "") }
        return lines.joined(separator: "\n")
    }

    // MARK: Markdown

    private static func markdown(_ r: WorkReceipt, _ o: WorkExportOptions, _ scope: Scope) -> String {
        var lines: [String] = []
        let multiDay = r.range.kind != .day
        if scope == .full {
            lines.append("## Work log · \(r.range.title)")
            lines.append("")
            lines.append("**\(Format.hm(r.activeMinutes))** active · " + summary(r, o, includeTime: false))
            if multiDay && !r.days.isEmpty {
                lines += ["", "| Day | Active | Projects |", "| --- | --- | --- |"]
                for d in r.days {
                    lines.append("| \(WorkRange.format("EEE d MMM", d.date)) | \(Format.hm(d.activeMinutes)) | \(escapeTable(d.projects.joined(separator: ", "))) |")
                }
            }
        }
        for p in r.projects {
            if scope != .session {
                if !lines.isEmpty { lines.append("") }
                lines.append("### \(p.name) · \(Format.hm(p.activeMinutes))" + (scope == .project ? " · \(r.range.title)" : ""))
                lines.append("")
            }
            for s in p.sessions {
                var meta = sessionMeta(s, o, multiDay: multiDay)
                if scope == .session { meta.insert(p.name, at: 0) }
                var line = "- **\(s.name)**" + (meta.isEmpty ? "" : " · " + meta.joined(separator: " · "))
                if o.files && !s.files.isEmpty {
                    let shown = s.files.prefix(6).map { "`\($0.name)`" }.joined(separator: ", ")
                    line += "  \n  " + shown + (s.files.count > 6 ? " +\(s.files.count - 6) more" : "")
                }
                lines.append(line)
            }
        }
        if r.isEmpty && scope == .full { lines += ["", "_No agent activity._"] }
        return lines.joined(separator: "\n")
    }

    // MARK: CSV

    /// One row per session per day, for timesheets.
    private static func csv(_ r: WorkReceipt) -> String {
        var rows = ["date,project,session,agent,model,start,end,active_minutes,active_hours,files,tokens,estimated_cost_usd"]
        for p in r.projects {
            for s in p.sessions {
                for key in s.dayKeys {
                    guard let day = Format.day(from: key) else { continue }
                    let lo = Int(day.timeIntervalSince1970 / 60), hi = Int(day.addingTimeInterval(86400).timeIntervalSince1970 / 60)
                    let minutes = s.minutes.filter { $0 >= lo && $0 < hi }
                    guard let first = minutes.first, let last = minutes.last else { continue }
                    let active = s.perDay[key] ?? 0
                    let share = s.activeMinutes > 0 ? Double(active) / Double(s.activeMinutes) : 0
                    rows.append([
                        key, p.name, s.name, s.provider.displayName, s.model ?? "",
                        Format.hourMinute(Date(timeIntervalSince1970: Double(first) * 60)),
                        Format.hourMinute(Date(timeIntervalSince1970: Double(last + 1) * 60)),
                        String(active), String(format: "%.2f", Double(active) / 60),
                        s.files.map(\.path).joined(separator: "; "),
                        String(Int((Double(s.tokens) * share).rounded())),
                        s.cost.map { String(format: "%.4f", $0 * share) } ?? "",
                    ].map(csvField).joined(separator: ","))
                }
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces

    static func summary(_ r: WorkReceipt, _ o: WorkExportOptions, includeTime: Bool = true) -> String {
        var parts: [String] = []
        if includeTime { parts.append("\(Format.hm(r.activeMinutes)) active") }
        parts.append(count(r.projects.count, "project"))
        parts.append(count(r.sessionCount, "session"))
        if r.fileCount > 0 { parts.append(count(r.fileCount, "file") + " changed") }
        if o.usage {
            if r.tokens > 0 { parts.append("\(Format.tokens(r.tokens)) tokens") }
            if let c = costLabel(r.cost, unpriced: r.hasUnpricedUsage) { parts.append(c + " API value") }
        }
        return parts.joined(separator: " · ")
    }

    private static func sessionMeta(_ s: WorkReceipt.Session, _ o: WorkExportOptions, multiDay: Bool) -> [String] {
        var meta = [s.provider.displayName]
        if o.times {
            meta.append(WorkReceipt.span(s, multiDay: multiDay))
            meta.append(Format.hm(s.activeMinutes))
        }
        if o.usage {
            if s.tokens > 0 { meta.append("\(Format.tokens(s.tokens)) tok") }
            if let c = costLabel(s.cost, unpriced: s.hasUnpricedUsage) { meta.append(c) }
        }
        return meta
    }

    static func costLabel(_ cost: Double?, unpriced: Bool) -> String? {
        guard let cost else { return nil }
        return "≈" + Format.usd(cost) + (unpriced ? "+" : "")
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    private static func escapeTable(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
}
