import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// MARK: - State

@MainActor
final class WorkLogState: ObservableObject {
    static let shared = WorkLogState()
    @Published private(set) var data: WorkLogData?
    @Published private(set) var isScanning = false
    /// Id of the item whose copy button last succeeded, for a brief checkmark.
    @Published var copiedID: String?

    private init() {}

    func scan(ifOlderThan age: TimeInterval = 0) {
        guard !isScanning else { return }
        if let data, Date().timeIntervalSince(data.scannedAt) < age { return }
        isScanning = true
        Task {
            data = await Task.detached(priority: .utility) { WorkLogScanner.scan() }.value
            isScanning = false
        }
    }

    func loadForPreview() {
        guard RenderFlags.isRendering else { return }
        data = WorkLogScanner.scan()
    }

    func receipt(_ range: WorkRange, priced: Bool = true) -> WorkReceipt? {
        guard let data else { return nil }
        let settings = AppSettings.shared
        let price = priced ? WorkReceipt.pricer(catalog: ModelPriceStore.shared.catalog, overrides: UsageAnalysisState.shared.rates)
                           : { _, _, _ in nil }
        return WorkReceipt.build(data.sessions, range: range, hidden: settings.hiddenWorkProjects,
                                 idleMinutes: settings.workIdleMinutes, price: price)
    }

    var options: WorkExportOptions {
        let s = AppSettings.shared
        return WorkExportOptions(files: s.workExportFiles, times: s.workExportTimes, usage: s.workExportUsage)
    }

    func copy(_ receipt: WorkReceipt, as format: WorkExportFormat? = nil, scope: WorkReceiptExport.Scope = .full, id: String = "receipt") {
        let text = WorkReceiptExport.render(receipt, as: format ?? AppSettings.shared.workCopyFormat, options: options, scope: scope)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(id)
    }

    func copyToday() {
        guard let receipt = receipt(.today()) else { scan(); return }
        copy(receipt, id: "today")
    }

    func copyImage(_ receipt: WorkReceipt, id: String = "image") {
        guard let image = ReceiptImage.render(receipt, options: options) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash(id)
    }

    /// The receipt as a PNG file, so dragging it into Slack, Mail or Finder drops a named image.
    func dragProvider(_ receipt: WorkReceipt) -> NSItemProvider {
        guard let image = ReceiptImage.render(receipt, options: options), let png = ReceiptImage.png(image) else { return NSItemProvider() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(receipt.range.fileStem + ".png")
        do { try png.write(to: url) } catch { return NSItemProvider(object: image) }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: image)
    }

    func save(_ receipt: WorkReceipt, as format: WorkExportFormat?) {
        let panel = NSSavePanel()
        let ext = format?.fileExtension ?? "png"
        panel.nameFieldStringValue = receipt.range.fileStem + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let format {
            try? WorkReceiptExport.render(receipt, as: format, options: options).write(to: url, atomically: true, encoding: .utf8)
        } else if let image = ReceiptImage.render(receipt, options: options), let png = ReceiptImage.png(image) {
            try? png.write(to: url)
        }
    }

    private func flash(_ id: String) {
        copiedID = id
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copiedID == id { copiedID = nil }
        }
    }
}

// MARK: - Dashboard page

struct WorkLogView: View {
    @ObservedObject private var state = WorkLogState.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var prices = ModelPriceStore.shared
    @State private var range: WorkRange
    @State private var cached: (key: Key, receipt: WorkReceipt)?
    @State private var showPreview = false

    private struct Key: Equatable {
        var scannedAt: Date?, range: WorkRange, hidden: Set<String>, idle: Int, prices: Date
    }

    init(range: WorkRange = .today()) { _range = State(initialValue: range) }

    private var key: Key {
        Key(scannedAt: state.data?.scannedAt, range: range, hidden: settings.hiddenWorkProjects,
            idle: settings.workIdleMinutes, prices: prices.catalog.updated)
    }

    private var receipt: WorkReceipt? {
        if let cached, cached.key == key { return cached.receipt }
        return state.receipt(range)
    }

    var body: some View {
        MaybeScroll {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let receipt {
                    stats(receipt)
                    actions(receipt)
                    if receipt.isEmpty {
                        emptyState
                    } else {
                        if range.kind == .day { WorkTimeline(receipt: receipt) }
                        else if receipt.days.count > 1 { dayChart(receipt) }
                        ForEach(receipt.projects) { ProjectCard(project: $0, receipt: receipt) }
                    }
                    footer(receipt)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading local agent logs…").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 28)
        }
        .onAppear { state.scan(ifOlderThan: 30); rebuild() }
        .onChange(of: key) { _, _ in rebuild() }
    }

    private func rebuild() {
        let key = key
        if let receipt = state.receipt(range) { cached = (key, receipt) }
    }

    // MARK: Header

    private var header: some View {
        PageHeader(title: "Work Log", subtitle: "What your agents worked on, read from local session logs.") {
            Picker("", selection: Binding(get: { range.kind }, set: { kind in
                range = WorkRange(kind, containing: range.contains(Date()) ? Date() : range.interval.start)
            })) { ForEach(WorkRange.Kind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 190).labelsHidden()
            HStack(spacing: 0) {
                stepButton("chevron.left", help: "Previous \(range.kind.rawValue.lowercased())") { range = range.shifted(by: -1) }
                Text(range.relativeTitle())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 140).help(range.title)
                stepButton("chevron.right", help: "Next \(range.kind.rawValue.lowercased())") { range = range.shifted(by: 1) }
                    .disabled(range.interval.end > Date())
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
            if !range.contains(Date()) {
                Button { range = .today(range.kind) } label: {
                    Text(range.kind == .day ? "Today" : "This \(range.kind.rawValue.lowercased())").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(ChipButtonStyle(compact: true))
            }
        }
    }

    private func stepButton(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Totals

    private func stats(_ r: WorkReceipt) -> some View {
        ReadoutStrip(items: [
            .init(value: Format.hm(r.activeMinutes), label: "active time"),
            .init(value: "\(r.projects.count)", label: r.projects.count == 1 ? "project" : "projects"),
            .init(value: "\(r.sessionCount)", label: r.sessionCount == 1 ? "session" : "sessions"),
            .init(value: "\(r.fileCount)", label: r.fileCount == 1 ? "file changed" : "files changed"),
            .init(value: r.tokens > 0 ? Format.tokens(r.tokens) : "—", label: "tokens"),
            .init(value: WorkReceiptExport.costLabel(r.cost, unpriced: r.hasUnpricedUsage) ?? "—", label: "API value, est."),
        ], leadSize: 34)
    }

    private func actions(_ r: WorkReceipt) -> some View {
        HStack(spacing: 8) {
            Button { state.copy(r) } label: {
                Label(state.copiedID == "receipt" ? "Copied" : "Copy receipt",
                      systemImage: state.copiedID == "receipt" ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy the whole \(range.kind.rawValue.lowercased()) as \(settings.workCopyFormat.rawValue.lowercased()) (⇧⌘C)")

            Button { showPreview.toggle() } label: {
                Label("Preview", systemImage: "receipt").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            }
            .buttonStyle(ChipButtonStyle())
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("See the receipt as it will be shared, then copy, save or drag it (⇧⌘P)")
            .popover(isPresented: $showPreview, arrowEdge: .bottom) {
                ReceiptPreview(receipt: r, maxPaperHeight: 560)
                    .padding(16).frame(width: 400)
                    .background(Theme.bg)
                    .preferredColorScheme(.dark)
            }

            Menu {
                Section("Copy") {
                    ForEach(WorkExportFormat.allCases) { f in Button("Copy as \(f.rawValue)") { state.copy(r, as: f) } }
                    Button("Copy Receipt Image") { state.copyImage(r) }
                }
                Section("Save") {
                    ForEach(WorkExportFormat.allCases) { f in Button("Save as \(f.rawValue)…") { state.save(r, as: f) } }
                    Button("Save Receipt Image…") { state.save(r, as: nil) }
                }
            } label: {
                Label(state.copiedID == "image" ? "Image copied" : "Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))

            Spacer(minLength: 12)

            Text("Copy as").font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            Picker("", selection: $settings.workCopyFormat) {
                Text("Text").tag(WorkExportFormat.text)
                Text("Markdown").tag(WorkExportFormat.markdown)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)

            Rectangle().fill(Theme.line).frame(width: 1, height: 20).padding(.horizontal, 4)
            Text("Include").font(.system(size: 11.5)).foregroundStyle(Theme.textMuted)
            IncludeChip(title: "Files", value: $settings.workExportFiles)
            IncludeChip(title: "Times", value: $settings.workExportTimes)
            IncludeChip(title: "Tokens & cost", value: $settings.workExportUsage)
        }
    }

    // MARK: Days

    private func dayChart(_ r: WorkReceipt) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Legend("Active time by day")
                    Spacer()
                    Text("\(r.days.count) active days").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Chart(r.days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", Double(d.activeMinutes) / 60))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .cornerRadius(2)
                }
                .chartXScale(domain: r.range.interval.start...r.range.interval.end)
                .chartYAxis { AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h").font(.system(size: 10)).foregroundStyle(Theme.textMuted) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: r.range.kind == .month ? 5 : 1)) { _ in
                    AxisValueLabel(format: r.range.kind == .month ? .dateTime.day() : .dateTime.weekday(.abbreviated)).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                } }
                .frame(height: 120)
            }
        }
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "receipt").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textMuted)
            Text("No agent activity \(range.kind == .day ? "on this day" : "this \(range.kind.rawValue.lowercased())")")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            Text("Claude Code, Codex and OpenCode sessions show up here as you work. Use the arrows to look at an earlier \(range.kind.rawValue.lowercased()).")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 20)
        .panel()
    }

    private func footer(_ r: WorkReceipt) -> some View {
        HStack(spacing: 14) {
            Menu {
                ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                    Toggle("\(m) minutes", isOn: Binding(get: { m == settings.workIdleMinutes }, set: { if $0 { settings.workIdleMinutes = m } }))
                }
            } label: {
                Text("Idle after \(settings.workIdleMinutes)m").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Activity less than this far apart counts as continuous work. Parallel sessions are counted once.")

            if !settings.hiddenWorkProjects.isEmpty {
                Menu {
                    ForEach(settings.hiddenWorkProjects.sorted(), id: \.self) { root in
                        Button("Show \((root as NSString).lastPathComponent)") { settings.hiddenWorkProjects.remove(root) }
                    }
                    Divider()
                    Button("Show All") { settings.hiddenWorkProjects = [] }
                } label: {
                    Text("\(settings.hiddenWorkProjects.count) hidden").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(r.hiddenProjects.isEmpty ? "Hidden projects are left out of the log and every export." :
                      "Hidden here: " + r.hiddenProjects.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            }
            Spacer()
            Text("Titles, file names and times only. Prompts and code never leave your logs.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
            Button { state.scan() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9.5, weight: .semibold))
                    Text(state.isScanning ? "Scanning…" : "Scanned \(Format.relative(state.data?.scannedAt))").font(.system(size: 11))
                }
                .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(state.isScanning)
            .help("Read the session logs again")
        }
    }
}

// MARK: - Day timeline

/// One lane per project across the working hours of the day; each mark is a minute an agent was active.
private struct WorkTimeline: View {
    var receipt: WorkReceipt
    private let maxLanes = 8

    private var bounds: (start: Date, end: Date) {
        let cal = Calendar.current
        let minutes = receipt.projects.flatMap { $0.sessions.flatMap(\.minutes) }
        let first = Date(timeIntervalSince1970: Double(minutes.min() ?? 0) * 60)
        let last = Date(timeIntervalSince1970: Double((minutes.max() ?? 0) + 1) * 60)
        var start = cal.dateInterval(of: .hour, for: first)?.start ?? first
        var end = cal.dateInterval(of: .hour, for: last)?.end ?? last
        if end.timeIntervalSince(start) < 4 * 3600 { end = start.addingTimeInterval(4 * 3600) }
        start = max(start, receipt.range.interval.start)
        end = min(end, receipt.range.interval.end)
        return (start, end)
    }

    var body: some View {
        let b = bounds
        let span = max(60, b.end.timeIntervalSince(b.start))
        let hours = Int((span / 3600).rounded())
        let step = hours > 12 ? 2 : 1
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Legend("Timeline")
                    Spacer()
                    Text("Each mark is a minute an agent was working").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                VStack(spacing: 6) {
                    ForEach(receipt.projects.prefix(maxLanes)) { project in
                        HStack(spacing: 12) {
                            Text(project.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                                .lineLimit(1).truncationMode(.middle).frame(width: 130, alignment: .leading)
                            lane(project, start: b.start, span: span, hours: hours, step: step)
                            Text(Format.hm(project.activeMinutes)).font(Theme.readout(13)).foregroundStyle(Theme.textPrimary)
                                .frame(width: 50, alignment: .trailing)
                        }
                        .frame(height: 18)
                    }
                    if receipt.projects.count > maxLanes {
                        Text("+\(receipt.projects.count - maxLanes) more projects below").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 142)
                    }
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 130, height: 1)
                        GeometryReader { geo in
                            ForEach(Array(stride(from: 0, through: hours, by: step)), id: \.self) { h in
                                Text(WorkRange.format("HH:mm", b.start.addingTimeInterval(Double(h) * 3600)))
                                    .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(Theme.textMuted)
                                    .fixedSize()
                                    .position(x: geo.size.width * CGFloat(Double(h) * 3600 / span), y: 6)
                            }
                        }
                        .frame(height: 12)
                        Color.clear.frame(width: 50, height: 1)
                    }
                }
            }
        }
    }

    private func lane(_ project: WorkReceipt.Project, start: Date, span: TimeInterval, hours: Int, step: Int) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(Theme.well))
            for h in stride(from: step, to: hours, by: step) {
                let x = size.width * CGFloat(Double(h) * 3600 / span)
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.05)))
            }
            let minuteWidth = max(1.5, size.width * 60 / CGFloat(span))
            for session in project.sessions {
                // Merge consecutive minutes into runs so long stretches draw as one bar.
                var runs: [(Int, Int)] = []
                for m in session.minutes {
                    if let last = runs.last, m == last.1 + 1 { runs[runs.count - 1].1 = m } else { runs.append((m, m)) }
                }
                for (a, b) in runs {
                    let x0 = size.width * CGFloat((Double(a) * 60 - start.timeIntervalSince1970) / span)
                    let x1 = size.width * CGFloat((Double(b + 1) * 60 - start.timeIntervalSince1970) / span)
                    let rect = CGRect(x: x0, y: 3, width: max(minuteWidth, x1 - x0), height: size.height - 6)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(session.provider.color))
                }
            }
        }
        .help(project.sessions.map { "\($0.name): \(WorkReceipt.span($0, multiDay: false))" }.joined(separator: "\n"))
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    var project: WorkReceipt.Project
    var receipt: WorkReceipt
    @ObservedObject private var state = WorkLogState.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(project.name).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        ForEach(project.providers) { ProviderDot(id: $0, size: 6).help($0.displayName) }
                        if !project.branches.isEmpty {
                            Text(project.branches.prefix(2).joined(separator: ", ")).font(Theme.mono(10.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        }
                    }
                    Text(project.displayPath).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.hm(project.activeMinutes)).font(Theme.readout(20)).foregroundStyle(Theme.textPrimary)
                    Text(details).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                CopyIconButton(id: project.id, help: "Copy this project's work") {
                    state.copy(receipt.only(project: project), scope: .project, id: project.id)
                }
                IconButton(systemImage: "eye.slash", help: "Hide \(project.name) from the log and exports (client or NDA work)") {
                    settings.hiddenWorkProjects.insert(project.id)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(spacing: 0) {
                ForEach(Array(project.sessions.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 34) }
                    SessionRow(session: s, receipt: receipt, multiDay: receipt.range.kind != .day)
                }
            }
            .padding(.vertical, 4)
        }
        .panel()
    }

    private var details: String {
        var parts = [WorkReceiptExport.count(project.sessions.count, "session")]
        if !project.files.isEmpty { parts.append(WorkReceiptExport.count(project.files.count, "file")) }
        if let c = WorkReceiptExport.costLabel(project.cost, unpriced: project.hasUnpricedUsage) { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

private struct SessionRow: View {
    var session: WorkReceipt.Session
    var receipt: WorkReceipt
    var multiDay: Bool
    @ObservedObject private var state = WorkLogState.shared
    @State private var hover = false
    private let maxFiles = 8

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProviderDot(id: session.provider, size: 6).padding(.top, 6).frame(width: 8)
                .help(session.provider.displayName)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(meta).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                if !session.files.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(session.files.prefix(maxFiles), id: \.path) { f in
                            HStack(spacing: 3) {
                                Text(f.name).font(Theme.mono(10.5)).foregroundStyle(Theme.textSecondary)
                                if f.edits > 1 { Text("×\(f.edits)").font(Theme.mono(10)).foregroundStyle(Theme.textMuted) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.well))
                            .help(f.path)
                        }
                        if session.files.count > maxFiles {
                            Text("+\(session.files.count - maxFiles) more").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .help(session.files.dropFirst(maxFiles).map(\.path).joined(separator: "\n"))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Text(Format.hm(session.activeMinutes)).font(Theme.readout(14)).foregroundStyle(Theme.textSecondary)
                .padding(.top, 1)
            CopyIconButton(id: session.id, help: "Copy this session") {
                state.copy(receipt.only(session: session), scope: .session, id: session.id)
            }
            .opacity(hover || state.copiedID == session.id ? 1 : 0.35)
        }
        .padding(.vertical, 9).padding(.horizontal, 14)
        .background(hover ? Color.white.opacity(0.025) : .clear)
        .onHover { hover = $0 }
    }

    private var meta: String {
        var parts = [session.provider.displayName]
        parts.append(WorkReceipt.span(session, multiDay: multiDay))
        if let m = session.model { parts.append(m) }
        if let b = session.branch { parts.append(b) }
        if session.tokens > 0 { parts.append("\(Format.tokens(session.tokens)) tok") }
        if let c = WorkReceiptExport.costLabel(session.cost, unpriced: session.hasUnpricedUsage) { parts.append(c) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Small buttons

struct CopyIconButton: View {
    var id: String
    var help: String
    var action: () -> Void
    @ObservedObject private var state = WorkLogState.shared

    var body: some View {
        let copied = state.copiedID == id
        IconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: help, tint: copied ? Theme.ok : Theme.textSecondary, action: action)
    }
}

// MARK: - Receipt preview

/// The receipt as it will be shared, with every way out of it underneath: copy, save, or drag.
struct ReceiptPreview: View {
    var receipt: WorkReceipt
    /// Tall receipts scroll inside this height.
    var maxPaperHeight: CGFloat = 520
    @ObservedObject private var state = WorkLogState.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var hoverPaper = false

    var body: some View {
        VStack(spacing: 12) {
            paper
            HStack(spacing: 6) {
                Text("Include").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                IncludeChip(title: "Times", value: $settings.workExportTimes)
                IncludeChip(title: "Files", value: $settings.workExportFiles)
                IncludeChip(title: "Tokens & cost", value: $settings.workExportUsage)
                Spacer(minLength: 0)
            }
            exportBar
        }
    }

    private var paper: some View {
        let sheet = ReceiptPaperView(receipt: receipt, options: state.options)
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: 12, y: 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        // Short receipts sit at their natural height; long ones scroll inside the limit.
        return ViewThatFits(in: .vertical) {
            sheet
            ScrollView(.vertical, showsIndicators: false) { sheet }
        }
        .frame(maxHeight: maxPaperHeight)
        .overlay(alignment: .bottom) {
            if hoverPaper {
                Label("Drag into Slack, Mail or Finder", systemImage: "hand.draw")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(.bottom, 14)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hoverPaper = h } }
        .onDrag { state.dragProvider(receipt) }
        .help("Drag the receipt out as a PNG")
        .accessibilityLabel("Work receipt for \(receipt.range.title), \(Format.hm(receipt.activeMinutes)) active")
    }

    private var exportBar: some View {
        let imageCopied = state.copiedID == "preview-image", textCopied = state.copiedID == "preview-text"
        let format = settings.workCopyFormat
        return HStack(spacing: 6) {
            Button { state.copyImage(receipt, id: "preview-image") } label: {
                Label(imageCopied ? "Copied" : "Copy image", systemImage: imageCopied ? "checkmark" : "photo")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .help("Copy the receipt as a picture, ready to paste into chat")

            Button { state.copy(receipt, id: "preview-text") } label: {
                Label(textCopied ? "Copied" : "Copy \(format == .markdown ? "Markdown" : "text")", systemImage: textCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle())
            .help("Copy the receipt as \(format.rawValue.lowercased())")

            Menu {
                Section("Copy") {
                    ForEach(WorkExportFormat.allCases.filter { $0 != format }) { f in
                        Button("Copy as \(f.rawValue)") { state.copy(receipt, as: f, id: "preview-text") }
                    }
                }
                Section("Save") {
                    Button("Save Image…") { state.save(receipt, as: nil) }
                    ForEach(WorkExportFormat.allCases) { f in Button("Save \(f.rawValue)…") { state.save(receipt, as: f) } }
                }
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 38, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.chipFill))
            .help("Other formats, or save to a file")
            .accessibilityLabel("Save or copy in another format")
        }
    }
}

/// An export option that can be switched on and off.
struct IncludeChip: View {
    var title: String
    @Binding var value: Bool

    var body: some View {
        Button { value.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: value ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(value ? Theme.textPrimary : Theme.textMuted)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(value ? Theme.chipSelected : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(value ? .clear : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(value ? .isSelected : [])
        .help(value ? "Exports include \(title.lowercased())" : "Exports leave out \(title.lowercased())")
    }
}

// MARK: - Receipt image

enum ReceiptImage {
    @MainActor
    static func render(_ receipt: WorkReceipt, options: WorkExportOptions) -> NSImage? {
        let renderer = ImageRenderer(content: ReceiptPaperView(receipt: receipt, options: options))
        renderer.scale = 2
        return renderer.nsImage
    }

    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// A till-receipt rendering of the log, for pasting into chat or saving as an image.
struct ReceiptPaperView: View {
    var receipt: WorkReceipt
    var options: WorkExportOptions
    private let ink = Color(hex: 0x2A2321)
    private let faded = Color(hex: 0x857A72)
    private let paper = Color(hex: 0xF7F2E8)
    private let maxProjects = 10, maxSessions = 5

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                VStack(spacing: 3) {
                    Text("USAGEBAR").font(.system(size: 17, weight: .heavy, design: .monospaced)).tracking(4)
                    Text("WORK RECEIPT").font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(2)
                    Text(receipt.range.title.uppercased()).font(.system(size: 11, design: .monospaced)).foregroundStyle(faded)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                rule
                if receipt.isEmpty {
                    Text("NO AGENT ACTIVITY").font(mono(11)).foregroundStyle(faded).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                ForEach(receipt.projects.prefix(maxProjects)) { p in
                    VStack(alignment: .leading, spacing: 3) {
                        row(p.name.uppercased(), Format.hm(p.activeMinutes), bold: true)
                        ForEach(p.sessions.prefix(maxSessions)) { s in
                            row("  " + s.name, options.times ? Format.hm(s.activeMinutes) : "", size: 10.5, color: faded)
                        }
                        if p.sessions.count > maxSessions {
                            row("  +\(p.sessions.count - maxSessions) more sessions", "", size: 10.5, color: faded)
                        }
                    }
                }
                if receipt.projects.count > maxProjects {
                    row("+\(receipt.projects.count - maxProjects) MORE PROJECTS", "", size: 10.5, color: faded)
                }
                rule
                VStack(alignment: .leading, spacing: 3) {
                    row("PROJECTS", "\(receipt.projects.count)", size: 10.5)
                    row("SESSIONS", "\(receipt.sessionCount)", size: 10.5)
                    if options.files { row("FILES CHANGED", "\(receipt.fileCount)", size: 10.5) }
                    if options.usage {
                        if receipt.tokens > 0 { row("TOKENS", Format.tokens(receipt.tokens), size: 10.5) }
                        if let c = WorkReceiptExport.costLabel(receipt.cost, unpriced: receipt.hasUnpricedUsage) { row("API VALUE", c, size: 10.5) }
                    }
                }
                rule
                row("TOTAL", Format.hm(receipt.activeMinutes), bold: true, size: 15)
                rule
                Text("* PROMPTS AND CODE STAY ON YOUR MAC *")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(faded).frame(maxWidth: .infinity).padding(.top, 2)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 14)
            .background(paper)
            ZigzagEdge().fill(paper).frame(height: 8)
        }
        .frame(width: 360)
        .environment(\.colorScheme, .light)
    }

    private func mono(_ size: CGFloat, bold: Bool = false) -> Font { .system(size: size, weight: bold ? .bold : .regular, design: .monospaced) }

    private func row(_ left: String, _ right: String, bold: Bool = false, size: CGFloat = 11.5, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(left).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Text(right).fixedSize()
        }
        .font(mono(size, bold: bold))
        .foregroundStyle(color ?? ink)
    }

    private var rule: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(faded.opacity(0.6)).frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
    }
}

struct ZigzagEdge: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let tooth: CGFloat = 10
            p.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x < rect.maxX {
                p.addLine(to: CGPoint(x: min(x + tooth / 2, rect.maxX), y: rect.maxY))
                p.addLine(to: CGPoint(x: min(x + tooth, rect.maxX), y: 0))
                x += tooth
            }
            p.closeSubpath()
        }
    }
}
