import SwiftUI

// MARK: - Look

extension Tier {
    var color: Color {
        switch self {
        case .safe: return Color(red: 0.11, green: 0.69, blue: 0.48)
        case .review: return Color(red: 0.92, green: 0.41, blue: 0.20)
        case .blocked: return Color.secondary
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .review: return "eye.circle.fill"
        case .blocked: return "lock.circle.fill"
        }
    }
}

extension ScanArea {
    var symbol: String {
        switch self {
        case .appCaches: return "shippingbox.fill"
        case .systemCaches: return "gearshape.2.fill"
        case .appLogs: return "doc.text.fill"
        case .systemLogs: return "exclamationmark.bubble.fill"
        case .oldVersions: return "clock.arrow.circlepath"
        case .leftoverSettings: return "slider.horizontal.3"
        case .leftoverData: return "folder.fill.badge.questionmark"
        case .leftoverWeb: return "globe"
        case .launchAgents: return "power"
        case .developer: return "hammer.fill"
        case .systemLeftovers: return "lock.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .appCaches: return .blue
        case .systemCaches: return .indigo
        case .appLogs: return .teal
        case .systemLogs: return .pink
        case .oldVersions: return .purple
        case .leftoverSettings: return .orange
        case .leftoverData: return .brown
        case .leftoverWeb: return .cyan
        case .launchAgents: return .red
        case .developer: return .gray
        case .systemLeftovers: return .mint
        }
    }
}

/// Square checkbox drawn from symbols so groups can show a mixed state.
struct CheckBox: View {
    let state: CheckState
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(disabled ? Color.secondary.opacity(0.4) : state == .off ? .secondary : .accentColor)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Small rounded tile with an SF Symbol, used for areas.
struct SymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.gradient))
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 320)
        } detail: {
            Detail(model: model)
        }
        .navigationTitle("Relinquish")
        .navigationSubtitle(model.subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.restore() } label: { Label("Restore", systemImage: "arrow.uturn.backward.circle") }
                    .labelStyle(.titleAndIcon)
                    .help("Put back the items of the last cleanup")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.busy || !model.canRestore)
                Button { model.scan() } label: { Label("Scan", systemImage: "magnifyingglass") }
                    .labelStyle(.titleAndIcon)
                    .help("Scan the ticked areas (⌘R)")
                    .keyboardShortcut("r")
                    .disabled(model.busy)
            }
        }
        .searchable(text: $model.filter, placement: .toolbar, prompt: "Filter results")
        .sheet(isPresented: $model.confirmClean) { ConfirmView(model: model) }
        .sheet(item: $model.report) { r in ReportView(report: r) { model.report = nil } }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.showRecovered ? "recovered" : model.focusArea?.rawValue ?? "all" },
                                set: { tag in
                                    model.showRecovered = tag == "recovered"
                                    model.focusArea = tag.flatMap(ScanArea.init(rawValue:))
                                })) {
            Section("Results") {
                HStack(spacing: 8) {
                    SymbolTile(symbol: "square.grid.2x2.fill", color: .accentColor)
                    Text("All Results")
                    Spacer()
                    if model.scanned { Text(Fmt.bytes(model.totalBytes)).foregroundColor(.secondary).monospacedDigit() }
                }
                .tag("all")
            }
            Section("History") {
                HStack(spacing: 8) {
                    SymbolTile(symbol: "chart.bar.fill", color: Tier.safe.color)
                    Text("Space Recovered")
                    Spacer()
                    if model.stats.total > 0 {
                        Text(Fmt.bytes(model.stats.total)).foregroundColor(.secondary).monospacedDigit()
                    }
                }
                .tag("recovered")
            }
            Section {
                ForEach(ScanArea.allCases) { a in AreaRow(model: model, area: a).tag(a.rawValue) }
            } header: {
                HStack {
                    Text("Scan")
                    Spacer()
                    Menu {
                        Button("Tick All") { ScanArea.allCases.forEach { model.toggleArea($0, true) } }
                        Button("Recommended") { model.areas = ScanArea.defaults }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(SolidForShots())
        .safeAreaInset(edge: .bottom) { TrashCard(model: model).padding(10) }
    }
}

struct AreaRow: View {
    @ObservedObject var model: AppModel
    let area: ScanArea

    var body: some View {
        HStack(spacing: 8) {
            CheckBox(state: model.areas.contains(area) ? .on : .off, disabled: model.busy) {
                model.toggleArea(area, !model.areas.contains(area))
            }
            .help(model.areas.contains(area) ? "Included in the next scan" : "Not scanned")
            SymbolTile(symbol: area.symbol, color: model.areas.contains(area) ? area.color : .gray)
            Text(area.title)
                .lineLimit(1)
                .foregroundColor(model.areas.contains(area) ? .primary : .secondary)
            Spacer(minLength: 4)
            let b = model.areaBytes(area)
            if model.scanned && b > 0 { Text(Fmt.bytes(b)).font(.callout).foregroundColor(.secondary).monospacedDigit() }
        }
        .help(area.detail)
    }
}

struct TrashCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.trashCount == 0 ? "trash" : "trash.fill")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Trash").fontWeight(.semibold)
                Text(trashLine).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Empty…") { model.confirmEmpty = true }
                .controlSize(.small)
                .disabled(model.busy || model.trashCount == 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .alert("Empty the Trash?", isPresented: $model.confirmEmpty) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(trashLine.lowercased()). It cannot be undone, and Restore Last Cleanup stops working.")
        }
    }

    private var trashLine: String {
        switch (model.trashCount, model.trashSize) {
        case let (n?, s?): return n == 0 ? "Empty" : "\(n) items, \(Fmt.bytes(s))"
        case let (n?, nil): return n == 0 ? "Empty" : "\(n) items"
        default: return "Everything in the Trash"
        }
    }
}

// MARK: - Detail

struct Detail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.scanning && model.scanned { GradientProgress(value: model.progress, height: 4).padding(.horizontal, 2) }
            if let b = model.banner { Banner(model: model, report: b) }
            if model.showRecovered {
                RecoveredView(model: model)
            } else if !model.scanned {
                if model.busy { Working(model: model) } else { Welcome(model: model) }
            } else if model.candidates.isEmpty {
                AllClean(model: model)
            } else {
                Summary(model: model)
                Divider()
                Results(model: model)
            }
        }
        .frame(minWidth: 600)
    }
}

struct Welcome: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 8) {
                Text("Let go of what your Mac no longer needs").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Tick what to scan on the left. Nothing changes until you pick items and move them to the Trash.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 12) {
                Promise(symbol: "checkmark.shield.fill", color: .green, text: "Never offers macOS, Mail, Keychains or iCloud data")
                Promise(symbol: "lock.fill", color: .orange, text: "Leaves alone anything a running app is using")
                Promise(symbol: "arrow.uturn.backward.circle.fill", color: .blue, text: "Moves to the Trash, so every cleanup can be undone")
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
            Button { model.scan() } label: {
                Label("Scan \(model.areas.count) Areas", systemImage: "magnifyingglass").frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.areas.isEmpty)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Promise: View {
    let symbol: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundColor(color).font(.system(size: 17)).frame(width: 22)
            Text(text)
        }
    }
}

struct Working: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Scanning your Mac").font(.system(size: 22, weight: .bold, design: .rounded))
            GradientProgress(value: model.progress, height: 14).frame(maxWidth: 460)
            HStack {
                Text(model.status).foregroundColor(.secondary)
                Spacer()
                Text("\(Int(model.progress * 100))%").monospacedDigit().foregroundColor(.secondary)
            }
            .frame(maxWidth: 460)
            .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Vibrant moving gradient that fills with the scan's progress.
struct GradientProgress: View {
    let value: Double
    var height: CGFloat = 10

    static let colors: [Color] = [
        Color(red: 1.00, green: 0.25, blue: 0.55), Color(red: 1.00, green: 0.55, blue: 0.15),
        Color(red: 1.00, green: 0.85, blue: 0.20), Color(red: 0.25, green: 0.85, blue: 0.45),
        Color(red: 0.15, green: 0.75, blue: 0.95), Color(red: 0.45, green: 0.40, blue: 1.00),
        Color(red: 1.00, green: 0.25, blue: 0.55),
    ]

    var body: some View {
        TimelineView(.animation) { t in
            let phase = CGFloat(t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.5) / 2.5)
            GeometryReader { g in
                let w = max(height, g.size.width * CGFloat(min(1, max(0, value))))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: GradientProgress.colors,
                                             startPoint: UnitPoint(x: -phase, y: 0.5), endPoint: UnitPoint(x: 2 - phase, y: 0.5)))
                        .frame(width: w)
                        .overlay(
                            Capsule().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                                .padding(.horizontal, 2).padding(.top, 1).frame(height: height / 2), alignment: .top)
                        .shadow(color: Color(red: 1, green: 0.3, blue: 0.6).opacity(0.45), radius: height * 0.6)
                        .animation(.easeOut(duration: 0.25), value: value)
                }
            }
        }
        .frame(height: height)
    }
}

struct AllClean: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 50)).foregroundColor(Tier.safe.color)
            Text("Nothing to clean").font(.title2).fontWeight(.semibold)
            Text("The ticked areas hold nothing left over. Tick more areas and scan again.").foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Banner: View {
    @ObservedObject var model: AppModel
    let report: CleanReport

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(report.skipped.isEmpty ? Tier.safe.color : Tier.review.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.headline).fontWeight(.semibold)
                if !report.skipped.isEmpty {
                    Text("\(report.skipped.count) items were left alone.").font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button("Details") { model.report = report }
            if report.kind == .clean && model.canRestore { Button("Undo") { model.restore() } }
            Button { model.banner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background((report.skipped.isEmpty ? Tier.safe.color : Tier.review.color).opacity(0.12))
    }
}

struct Summary: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.focusArea?.title ?? "Your selection")
                        .font(.headline).foregroundColor(.secondary)
                    if model.selectedItems.isEmpty {
                        Text("Pick what to clean")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Nothing is selected for you. Tick items below, or use Select All on a group.")
                            .font(.callout).foregroundColor(.secondary)
                    } else {
                        Text(Fmt.bytes(model.selectedBytes))
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(model.selectionLine).font(.callout).foregroundColor(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if model.busy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(model.status).font(.caption) }
                            .foregroundColor(.secondary)
                    }
                    Button { model.confirmClean = true } label: {
                        Label(model.selectedItems.isEmpty ? "Move to Trash…" : "Move \(model.selectedItems.count) to Trash…",
                              systemImage: "trash").frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.busy || model.selectedItems.isEmpty)
                    Text("You review the list before anything moves").font(.caption).foregroundColor(.secondary)
                }
            }
            TierBar(model: model)
            HStack(spacing: 18) {
                ForEach(Tier.allCases) { t in
                    HStack(spacing: 6) {
                        Circle().fill(t.color).frame(width: 8, height: 8)
                        Text(t.title).fontWeight(.medium)
                        Text("\(model.items(t).count) · \(Fmt.bytes(model.bytes(t)))").foregroundColor(.secondary)
                    }
                    .font(.callout)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
    }
}

/// One bar split by tier size, like a storage bar.
struct TierBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { g in
            let total = max(1, Tier.allCases.reduce(Int64(0)) { $0 + model.bytes($1) })
            HStack(spacing: 2) {
                ForEach(Tier.allCases) { t in
                    let w = CGFloat(Double(model.bytes(t)) / Double(total)) * (g.size.width - 4)
                    if w > 0.5 {
                        Rectangle().fill(t == .blocked ? Color.secondary.opacity(0.35) : t.color).frame(width: max(3, w))
                    }
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct Results: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(Tier.allCases) { tier in
                let groups = model.groups(tier)
                if !groups.isEmpty {
                    Section {
                        ForEach(groups) { g in AreaGroup(model: model, group: g) }
                    } header: {
                        TierHeader(model: model, tier: tier)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

struct TierHeader: View {
    @ObservedObject var model: AppModel
    let tier: Tier

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tier.symbol).foregroundColor(tier.color).font(.system(size: 15))
            Text(tier.title).font(.system(size: 14, weight: .semibold))
            Text(tier.note).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer()
            if tier != .blocked {
                Button("Select All") { model.setAll(tier, true) }.buttonStyle(.link)
                Button("None") { model.setAll(tier, false) }.buttonStyle(.link)
            }
        }
        .padding(.vertical, 6)
    }
}

struct AreaGroup: View {
    @ObservedObject var model: AppModel
    let group: ResultGroup

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { model.expanded.contains(group.id) || !model.filter.isEmpty },
                                            set: { model.setExpanded(group.id, $0) })) {
            ForEach(group.items) { c in ItemRow(model: model, c: c) }
        } label: {
            HStack(spacing: 10) {
                CheckBox(state: model.state(of: group.items), disabled: group.tier == .blocked || model.busy) {
                    model.toggle(group.items)
                }
                SymbolTile(symbol: group.area.symbol, color: group.area.color, size: 24)
                Text(group.area.title).fontWeight(.medium)
                Text("\(group.items.count)")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                Text(Fmt.bytes(group.bytes)).monospacedDigit().foregroundColor(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { model.setExpanded(group.id, !model.expanded.contains(group.id)) }
        }
    }
}

struct ItemRow: View {
    @ObservedObject var model: AppModel
    let c: Candidate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CheckBox(state: model.isSelected(c) ? .on : .off, disabled: c.tier == .blocked || model.busy) {
                model.set(c, !model.isSelected(c))
            }
            .padding(.top, 2)
            if let icon = model.icon(for: c) {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: FS.isDirectory(c.url) ? "folder" : "doc")
                    .font(.system(size: 17)).foregroundColor(.secondary).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if c.admin { PasswordBadge() }
                }
                Text(c.reason).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(c.displayPath).font(.caption).foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.bytes(c.size)).monospacedDigit()
                SizeBar(fraction: model.sizeFraction(c), color: c.tier.color)
            }
        }
        .padding(.vertical, 4)
        .opacity(c.tier == .blocked ? 0.65 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.url.path, forType: .string)
            }
            if c.tier != .blocked {
                Divider()
                Button(model.isSelected(c) ? "Deselect" : "Select") { model.set(c, !model.isSelected(c)) }
            }
        }
    }
}

/// Lock on items owned by the system; the tooltip says why.
struct PasswordBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.mint)
            .help("Requires admin privileges. macOS asks for your password once when you move these.")
            .accessibilityLabel("Requires admin privileges")
    }
}

struct SizeBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule().fill(color.opacity(0.8)).frame(width: max(2, 60 * fraction))
        }
        .frame(width: 60, height: 4)
    }
}

struct ReportView: View {
    let report: CleanReport
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(report.title).font(.title2).fontWeight(.semibold)
            if !report.done.isEmpty {
                Text("\(report.done.count) items, \(Fmt.bytes(report.bytes))").foregroundColor(.secondary)
            }
            List {
                if !report.skipped.isEmpty {
                    Section(header: Text("Left alone")) {
                        ForEach(report.skipped.indices, id: \.self) { i in
                            VStack(alignment: .leading) {
                                Text(report.skipped[i].path).lineLimit(1).truncationMode(.middle)
                                Text(report.skipped[i].why.prefix(1).uppercased() + report.skipped[i].why.dropFirst())
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if !report.done.isEmpty {
                    Section(header: Text("Done")) {
                        ForEach(report.done.indices, id: \.self) { i in
                            HStack {
                                Text(report.done[i].path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(Fmt.bytes(report.done[i].size)).monospacedDigit().foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            HStack { Spacer(); Button("OK", action: close).keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 560, height: 420)
    }
}

/// Lists every selected item before anything is moved; nothing moves without this explicit click.
struct ConfirmView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let items = model.selectedItems.sorted { $0.size > $1.size }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 34)).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move \(items.count) items to the Trash?").font(.title3).fontWeight(.semibold)
                    Text("\(Fmt.bytes(model.selectedBytes)). Check the list; untick anything you want to keep.")
                        .foregroundColor(.secondary)
                }
            }
            List {
                ForEach(items) { c in
                    HStack(spacing: 10) {
                        CheckBox(state: .on) { model.set(c, false) }
                        Image(systemName: c.tier.symbol).foregroundColor(c.tier.color)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) { Text(c.name).lineLimit(1).truncationMode(.middle); if c.admin { PasswordBadge() } }
                            Text(c.displayPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Fmt.bytes(c.size)).monospacedDigit().foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            if model.adminSelected > 0 {
                Label("\(model.adminSelected) system-wide items need administrator rights. macOS will ask for your password once; Relinquish never sees it.",
                      systemImage: "lock.shield.fill")
                    .font(.callout).foregroundColor(.mint)
            }
            Text("Each item is checked again first; anything that came into use is skipped. Restore puts everything back until the Trash is emptied.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.confirmClean = false }
                    .keyboardShortcut(.cancelAction)
                Button("Move \(items.count) Items to Trash") { model.confirmClean = false; model.clean() }
                    .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

/// Screenshots cannot capture the translucent sidebar; LC_SHOT renders it solid.
struct SolidForShots: ViewModifier {
    func body(content: Content) -> some View {
        if ProcessInfo.processInfo.environment["LC_SHOT"] != nil {
            content.scrollContentBackground(.hidden).background(Color(nsColor: .underPageBackgroundColor))
        } else {
            content
        }
    }
}

// MARK: - Space Recovered

struct RecoveredView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let s = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space Recovered").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(model.firstRun.map { "Since you first ran Relinquish on \($0.formatted(date: .long, time: .omitted))" }
                         ?? "Since you first ran Relinquish")
                        .foregroundColor(.secondary)
                }
                if s.sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "chart.bar").font(.system(size: 40)).foregroundColor(.secondary)
                        Text("Nothing recovered yet").font(.title3).fontWeight(.semibold)
                        Text("Space you clean shows up here, grouped by category.").foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 60)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        StatTile(title: "Recovered", value: Fmt.bytes(s.total),
                                 note: "\(itemsText(s.items)) in \(s.sessions.count == 1 ? "1 cleanup" : "\(s.sessions.count) cleanups")", strong: true)
                        StatTile(title: "Freed for good", value: Fmt.bytes(s.freed), note: "The Trash was emptied")
                        StatTile(title: "Waiting in the Trash", value: Fmt.bytes(s.inTrash),
                                 note: s.inTrash > 0 ? "Empty the Trash to free it" : "Nothing waiting")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Card(title: "By category") {
                        HStack(spacing: 14) {
                            LegendKey(faded: false, label: "Freed")
                            LegendKey(faded: true, label: "In the Trash")
                            Spacer()
                        }
                        .font(.caption)
                        let top = max(1, s.categories.map(\.total).max() ?? 1)
                        ForEach(s.categories) { c in CategoryRow(c: c, top: top) }
                    }
                    Card(title: "Cleanups") {
                        ForEach(s.sessions) { x in SessionRow(x: x) }
                    }
                    if s.restored > 0 {
                        Text("\(Fmt.bytes(s.restored)) you put back with Restore is not counted.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let note: String
    var strong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: strong ? 30 : 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(strong ? AnyShapeStyle(RecoveredGradient.track) : AnyShapeStyle(Color.primary))
            Text(note).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// "1 item", "3 items".
func itemsText(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

struct Card<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

enum RecoveredGradient {
    static let colors: [Color] = [
        Color(red: 0.11, green: 0.69, blue: 0.48), Color(red: 0.12, green: 0.74, blue: 0.80),
        Color(red: 0.28, green: 0.52, blue: 1.00), Color(red: 0.62, green: 0.38, blue: 1.00),
    ]
    static var track: LinearGradient { LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing) }
}

struct LegendKey: View {
    let faded: Bool
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(RecoveredGradient.track).opacity(faded ? 0.35 : 1).frame(width: 18, height: 10)
            Text(label).foregroundColor(.secondary)
        }
    }
}

/// One category: a thin bar split into freed and still-in-Trash, scaled to the largest category.
struct CategoryRow: View {
    let c: RecoveredStats.Category
    let top: Int64

    var body: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: c.area.symbol, color: c.area.color, size: 22)
            Text(c.area.title).frame(width: 170, alignment: .leading).lineLimit(1)
            GeometryReader { g in
                let w = g.size.width
                let fw = c.freed > 0 ? max(4, CGFloat(Double(c.freed) / Double(top)) * w) : 0
                let tw = c.inTrash > 0 ? max(4, CGFloat(Double(c.inTrash) / Double(top)) * w) : 0
                // one gradient spans the whole track; each bar reveals its share of it
                RecoveredGradient.track
                    .frame(width: w)
                    .mask(
                        HStack(spacing: 2) {
                            if fw > 0 { RoundedRectangle(cornerRadius: 4).frame(width: fw) }
                            if tw > 0 { RoundedRectangle(cornerRadius: 4).opacity(0.35).frame(width: tw) }
                            Spacer(minLength: 0)
                        }
                    )
            }
            .frame(height: 10)
            Text(Fmt.bytes(c.total)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Text(itemsText(c.items)).font(.caption).foregroundColor(.secondary).frame(width: 64, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .help("\(c.area.title): \(Fmt.bytes(c.freed)) freed, \(Fmt.bytes(c.inTrash)) in the Trash, \(itemsText(c.items))")
    }
}

struct SessionRow: View {
    let x: RecoveredStats.Session

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(x.date.formatted(date: .abbreviated, time: .shortened))
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.14)))
            Text(Fmt.bytes(x.freed + x.inTrash)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
    }

    private var detail: String {
        if x.state == .restored { return "\(itemsText(x.restoredItems)) put back with Restore" }
        var s = itemsText(x.items)
        if x.admin > 0 { s += " · \(x.admin) system-wide" }
        if x.restoredItems > 0 { s += " · \(x.restoredItems) put back" }
        return s
    }

    private var label: String {
        switch x.state {
        case .freed: return "Freed"
        case .inTrash: return "In the Trash"
        case .restored: return "Restored"
        case .partlyRestored: return "Partly restored"
        }
    }

    private var icon: String {
        switch x.state {
        case .freed: return "checkmark.circle.fill"
        case .inTrash: return "trash.circle.fill"
        case .restored, .partlyRestored: return "arrow.uturn.backward.circle.fill"
        }
    }

    private var color: Color {
        switch x.state {
        case .freed: return Tier.safe.color
        case .inTrash: return .accentColor
        case .restored, .partlyRestored: return .secondary
        }
    }
}
