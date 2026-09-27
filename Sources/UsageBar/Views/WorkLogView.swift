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

    func copyImage(_ receipt: WorkReceipt) {
        guard let image = ReceiptImage.render(receipt, options: options) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash("image")
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
            VStack(alignment: .leading, spacing: 16) {
                header
                if let receipt {
                    stats(receipt)
                    actions(receipt)
                    if receipt.isEmpty {
                        emptyState
                    } else {
                        if range.kind != .day && receipt.days.count > 1 { dayChart(receipt) }
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
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 20)
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Work Log").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("What your agents worked on, read from local session logs").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Picker("", selection: Binding(get: { range.kind }, set: { kind in
                range = WorkRange(kind, containing: range.contains(Date()) ? Date() : range.interval.start)
            })) { ForEach(WorkRange.Kind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 200).labelsHidden()
            HStack(spacing: 2) {
                stepButton("chevron.left", help: "Previous \(range.kind.rawValue.lowercased())") { range = range.shifted(by: -1) }
                Text(range.relativeTitle())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 150).help(range.title)
                stepButton("chevron.right", help: "Next \(range.kind.rawValue.lowercased())") { range = range.shifted(by: 1) }
                    .disabled(range.interval.end > Date())
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chipFill))
            if !range.contains(Date()) {
                Button { range = .today(range.kind) } label: {
                    Text("Today").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private func stepButton(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Totals

    private func stats(_ r: WorkReceipt) -> some View {
        HStack(spacing: 10) {
            StatTile(value: Format.hm(r.activeMinutes), label: "active time", tint: Theme.accent)
            StatTile(value: "\(r.projects.count)", label: r.projects.count == 1 ? "project" : "projects")
            StatTile(value: "\(r.sessionCount)", label: r.sessionCount == 1 ? "session" : "sessions")
            StatTile(value: "\(r.fileCount)", label: "files changed")
            StatTile(value: r.tokens > 0 ? Format.tokens(r.tokens) : "—", label: "tokens")
            StatTile(value: WorkReceiptExport.costLabel(r.cost, unpriced: r.hasUnpricedUsage) ?? "—", label: "API value (est.)")
        }
    }

    private func actions(_ r: WorkReceipt) -> some View {
        Card(padding: 12) {
            HStack(spacing: 10) {
                Button { state.copy(r) } label: {
                    Label(state.copiedID == "receipt" ? "Copied" : "Copy receipt",
                          systemImage: state.copiedID == "receipt" ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(ChipButtonStyle(selected: true))
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the whole \(range.kind.rawValue.lowercased()) as \(settings.workCopyFormat.rawValue.lowercased()) (⇧⌘C)")

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
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chipFill))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))

                Spacer(minLength: 8)

                Text("Copy as").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Picker("", selection: $settings.workCopyFormat) {
                    Text("Text").tag(WorkExportFormat.text)
                    Text("Markdown").tag(WorkExportFormat.markdown)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)

                Rectangle().fill(Theme.divider).frame(width: 1, height: 22)
                Text("Include").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                toggleChip("Files", $settings.workExportFiles)
                toggleChip("Times", $settings.workExportTimes)
                toggleChip("Tokens & cost", $settings.workExportUsage)
            }
        }
    }

    private func toggleChip(_ title: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: value.wrappedValue ? "checkmark.square.fill" : "square").font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(value.wrappedValue ? Theme.textPrimary : Theme.textMuted)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(value.wrappedValue ? Theme.chipSelected : Theme.chipFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Days

    private func dayChart(_ r: WorkReceipt) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Active time by day").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(r.days.count) active days").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Chart(r.days) { d in
                    BarMark(x: .value("Day", d.date, unit: .day), y: .value("Hours", Double(d.activeMinutes) / 60))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                        .cornerRadius(3)
                }
                .chartXScale(domain: r.range.interval.start...r.range.interval.end)
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Theme.divider)
                    AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h").font(.system(size: 10)).foregroundStyle(Theme.textMuted) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: r.range.kind == .month ? 5 : 1)) { _ in
                    AxisValueLabel(format: r.range.kind == .month ? .dateTime.day() : .dateTime.weekday(.abbreviated)).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                } }
                .frame(height: 110)
            }
        }
    }

    // MARK: Empty / footer

    private var emptyState: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "receipt").font(.system(size: 26)).foregroundStyle(Theme.textMuted)
                Text("No agent activity \(range.kind == .day ? "on this day" : "this \(range.kind.rawValue.lowercased())")")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text("Claude Code, Codex and OpenCode sessions show up here as you work.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private func footer(_ r: WorkReceipt) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                    Button { settings.workIdleMinutes = m } label: {
                        HStack { Text("\(m) minutes"); if m == settings.workIdleMinutes { Image(systemName: "checkmark") } }
                    }
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
                .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            Button { state.scan() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold))
                    Text(state.isScanning ? "Scanning…" : "Scanned \(Format.relative(state.data?.scannedAt))").font(.system(size: 11))
                }
                .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(state.isScanning)
        }
    }
}

// MARK: - Project card

private struct ProjectCard: View {
    var project: WorkReceipt.Project
    var receipt: WorkReceipt
    @ObservedObject private var state = WorkLogState.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            ForEach(project.providers) { ProviderDot(id: $0, size: 7).help($0.displayName) }
                            if !project.branches.isEmpty {
                                Text(project.branches.prefix(2).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                            }
                        }
                        Text(project.displayPath).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.hm(project.activeMinutes)).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                        Text(details).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    CopyIconButton(id: project.id, help: "Copy this project's work") {
                        state.copy(receipt.only(project: project), scope: .project, id: project.id)
                    }
                    IconButton(systemImage: "eye.slash", help: "Hide \(project.name) from the log and exports (client or NDA work)") {
                        settings.hiddenWorkProjects.insert(project.id)
                    }
                }
                Rectangle().fill(Theme.divider).frame(height: 1)
                VStack(spacing: 2) {
                    ForEach(project.sessions) { SessionRow(session: $0, receipt: receipt, multiDay: receipt.range.kind != .day) }
                }
            }
        }
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
            ProviderDot(id: session.provider, size: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Text(meta).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                if !session.files.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(session.files.prefix(maxFiles), id: \.path) { f in
                            HStack(spacing: 3) {
                                Text(f.name).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                                if f.edits > 1 { Text("×\(f.edits)").font(.system(size: 10)).foregroundStyle(Theme.textMuted) }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.chipFill))
                            .help(f.path)
                        }
                        if session.files.count > maxFiles {
                            Text("+\(session.files.count - maxFiles) more").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .help(session.files.dropFirst(maxFiles).map(\.path).joined(separator: "\n"))
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Text(Format.hm(session.activeMinutes)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .padding(.top, 1)
            CopyIconButton(id: session.id, help: "Copy this session") {
                state.copy(receipt.only(session: session), scope: .session, id: session.id)
            }
            .opacity(hover || state.copiedID == session.id ? 1 : 0.55)
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.white.opacity(0.03) : .clear))
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

struct IconButton: View {
    var systemImage: String
    var help: String
    var tint: Color = Theme.textSecondary
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? Theme.textPrimary : tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.white.opacity(0.1) : Theme.chipFill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

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
