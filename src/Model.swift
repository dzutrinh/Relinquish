import AppKit

enum CheckState { case on, off, mixed }

/// Items of one area inside one tier, shown as a collapsible group.
struct ResultGroup: Identifiable {
    let tier: Tier
    let area: ScanArea
    let items: [Candidate]
    var id: String { "\(tier.rawValue)-\(area.rawValue)" }
    var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

final class AppModel: ObservableObject {
    @Published var candidates: [Candidate] = []
    @Published var selection = Set<String>()
    @Published var areas: Set<ScanArea> { didSet { saveAreas() } }
    @Published var busy = false
    @Published var scanning = false
    @Published var progress: Double = 0
    @Published var status = "Tick what to scan, then press Scan."
    @Published var scanned = false
    @Published var protectedCount = 0
    @Published var needsAdmin = 0
    @Published var unreadable = 0
    @Published var filter = ""
    @Published var focusArea: ScanArea?
    @Published var expanded = Set<String>()
    @Published var confirmClean = false
    @Published var confirmEmpty = false
    @Published var report: CleanReport?
    @Published var banner: CleanReport?
    @Published var canRestore = false
    @Published var trashSize: Int64?
    @Published var trashCount: Int?
    @Published var showRecovered = false
    @Published var stats = RecoveredStats()
    @Published var firstRun: Date?

    let cleaner = Cleaner()
    let trash = TrashBin.user
    private let areasKey = "scanAreas"
    private var icons: [String: NSImage?] = [:]

    init() {
        if ProcessInfo.processInfo.environment["LC_DEMO"] == nil {
            Migration.run(newHistory: cleaner.historyDir)
        }
        if let saved = UserDefaults.standard.stringArray(forKey: areasKey) {
            areas = Set(saved.compactMap(ScanArea.init(rawValue:)))
        } else {
            areas = ScanArea.defaults
        }
        canRestore = cleaner.canRestore
        refreshTrash()
        refreshStats()
    }

    private let firstRunKey = "firstRun"

    /// Re-reads the cleanup logs; the first-run date is the earlier of the stored date and the oldest log.
    func refreshStats() {
        if DemoData.enabled { stats = DemoData.stats(); firstRun = DemoData.firstRun; return }
        let dir = cleaner.historyDir
        DispatchQueue.global(qos: .utility).async {
            let s = RecoveredStats.load(from: dir)
            DispatchQueue.main.async {
                self.stats = s
                let stored = UserDefaults.standard.object(forKey: self.firstRunKey) as? Date
                let first = ([stored, s.sessions.last?.date].compactMap { $0 } + [Date()]).min()!
                if stored != first && self.persistAreas { UserDefaults.standard.set(first, forKey: self.firstRunKey) }
                self.firstRun = first
            }
        }
    }

    /// Demo and screenshot runs must not change the user's saved choice.
    var persistAreas = ProcessInfo.processInfo.environment["LC_DEMO"] == nil

    private func saveAreas() {
        guard persistAreas else { return }
        UserDefaults.standard.set(areas.map(\.rawValue).sorted(), forKey: areasKey)
    }

    // MARK: - Derived

    private func visible(_ c: Candidate) -> Bool {
        if let a = focusArea, c.area != a { return false }
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty || c.displayPath.lowercased().contains(f) || c.reason.lowercased().contains(f)
    }

    func items(_ tier: Tier) -> [Candidate] {
        candidates.filter { $0.tier == tier && visible($0) }.sorted { $0.size > $1.size }
    }

    func groups(_ tier: Tier) -> [ResultGroup] {
        let rows = items(tier)
        return ScanArea.allCases.compactMap { a in
            let g = rows.filter { $0.area == a }
            return g.isEmpty ? nil : ResultGroup(tier: tier, area: a, items: g)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var selectedItems: [Candidate] { candidates.filter { selection.contains($0.id) && $0.tier != .blocked } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.size } }
    func bytes(_ tier: Tier) -> Int64 { items(tier).reduce(0) { $0 + $1.size } }
    func areaBytes(_ a: ScanArea) -> Int64 { candidates.filter { $0.area == a }.reduce(0) { $0 + $1.size } }

    private var largest: Int64 = 1
    func sizeFraction(_ c: Candidate) -> Double { Double(c.size) / Double(max(1, largest)) }

    var subtitle: String {
        if busy { return status }
        if !scanned { return "Not scanned yet" }
        return "\(candidates.count) items found · \(Fmt.bytes(totalBytes))"
    }

    var adminSelected: Int { selectedItems.filter(\.admin).count }

    var selectionLine: String {
        let sel = selectedItems
        if sel.isEmpty { return "Nothing selected. Tick items below." }
        let fromReview = sel.filter { $0.tier == .review }.count
        var s = "\(sel.count) items selected"
        if fromReview > 0 { s += ", \(fromReview) from Review first" }
        return s
    }

    func isSelected(_ c: Candidate) -> Bool { selection.contains(c.id) }

    func set(_ c: Candidate, _ on: Bool) {
        guard c.tier != .blocked else { return }
        if on { selection.insert(c.id) } else { selection.remove(c.id) }
    }

    func state(of items: [Candidate]) -> CheckState {
        let pickable = items.filter { $0.tier != .blocked }
        let n = pickable.filter { selection.contains($0.id) }.count
        return n == 0 ? .off : n == pickable.count ? .on : .mixed
    }

    func toggle(_ items: [Candidate]) {
        let on = state(of: items) != .on
        for c in items { set(c, on) }
    }

    func setAll(_ tier: Tier, _ on: Bool) {
        guard tier != .blocked else { return }
        for c in items(tier) { set(c, on) }
    }

    func setExpanded(_ id: String, _ on: Bool) {
        if on { expanded.insert(id) } else { expanded.remove(id) }
    }

    func toggleArea(_ a: ScanArea, _ on: Bool) {
        if on { areas.insert(a) } else { areas.remove(a) }
    }

    /// The owning app's icon when it can be found (bundle id or app name), else nil.
    func icon(for c: Candidate) -> NSImage? {
        let key = AppIndex.stripExt(c.app ?? c.owner ?? c.url.lastPathComponent)
        if let hit = icons[key] { return hit }
        var found: NSImage?
        let ws = NSWorkspace.shared
        if AppIndex.isBundleID(key), let url = ws.urlForApplication(withBundleIdentifier: key) {
            found = ws.icon(forFile: url.path)
        } else {
            for dir in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
                let p = "\(dir)/\(key).app"
                if FileManager.default.fileExists(atPath: p) { found = ws.icon(forFile: p); break }
            }
        }
        icons[key] = found
        return found
    }

    // MARK: - Actions

    func scan() {
        guard !busy else { return }
        let chosen = areas
        guard !chosen.isEmpty else { status = "Tick at least one area to scan."; return }
        busy = true
        scanning = true
        progress = 0
        banner = nil
        status = "Looking at installed and running apps…"
        DispatchQueue.global(qos: .userInitiated).async {
            let index = AppIndex.live()
            self.post("Checking which files are open…", 0.08)
            let open = PathSet.openFiles(under: FS.openFileRoots)
            self.post("Scanning…", 0.15)
            let result = Scanner(index: index, open: open, areas: chosen).scan { step, f in
                self.post("\(step)…", 0.15 + 0.85 * f)
            }
            DispatchQueue.main.async { self.apply(result) }
        }
    }

    func apply(_ result: ScanResult) {
        candidates = result.candidates
        largest = result.candidates.map(\.size).max() ?? 1
        selection = []   // never pre-select: the user picks every item
        expanded = Set(Tier.allCases.flatMap { t in groups(t).filter { t == .review || $0.items.count <= 3 }.map(\.id) })
        protectedCount = result.protectedCount
        needsAdmin = result.needsAdmin
        unreadable = result.unreadable
        scanned = true
        busy = false
        scanning = false
        progress = 1
        status = "Found \(result.candidates.count) items. Nothing has been changed."
        refreshTrash()
    }

    private func post(_ s: String, _ p: Double? = nil) {
        DispatchQueue.main.async {
            self.status = s
            if let p = p { self.progress = max(self.progress, p) }
        }
    }

    func clean() {
        let items = selectedItems
        guard !items.isEmpty, !busy else { return }
        busy = true
        status = "Checking each item again…"
        DispatchQueue.global(qos: .userInitiated).async {
            // fresh view of the system: an app may have started since the scan
            let index = AppIndex.live()
            let open = PathSet.openFiles(under: FS.openFileRoots)
            let r = self.cleaner.clean(items, index: index, open: open)
            DispatchQueue.main.async {
                let moved = Set(r.done.map(\.path))
                self.candidates.removeAll { moved.contains($0.displayPath) }
                self.selection = self.selection.filter { id in self.candidates.contains { $0.id == id } }
                self.banner = r
                self.busy = false
                self.canRestore = self.cleaner.canRestore
                self.refreshTrash()
                self.refreshStats()
            }
        }
    }

    func restore() {
        guard !busy else { return }
        busy = true
        status = "Putting items back…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.cleaner.restoreLast()
            DispatchQueue.main.async {
                self.banner = r
                self.busy = false
                self.canRestore = self.cleaner.canRestore
                self.refreshTrash()
                self.refreshStats()
                if !r.done.isEmpty && self.scanned { self.scan() }
            }
        }
    }

    func emptyTrash() {
        guard !busy else { return }
        busy = true
        status = "Emptying the Trash…"
        DispatchQueue.global(qos: .userInitiated).async {
            let err = self.trash.empty()
            if err == nil { self.cleaner.retireHistory() }
            DispatchQueue.main.async {
                self.busy = false
                self.canRestore = self.cleaner.canRestore
                var r = CleanReport(title: "Empty Trash", kind: .trash)
                if let err = err { r.skipped = [("Trash", err)] }
                self.banner = r
                self.refreshTrash()
                self.refreshStats()
            }
        }
    }

    func refreshTrash() {
        if DemoData.enabled { trashCount = 9; trashSize = 1_310_000_000; return }
        DispatchQueue.global(qos: .utility).async {
            let size = self.trash.size()
            let count = self.trash.itemCount()
            DispatchQueue.main.async { self.trashSize = size; self.trashCount = count }
        }
    }
}
