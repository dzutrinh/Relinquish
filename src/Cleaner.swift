import Foundation

protocol Trasher {
    /// Moves the item to the Trash and returns where it landed.
    func trash(_ url: URL) throws -> URL?
}

struct SystemTrasher: Trasher {
    func trash(_ url: URL) throws -> URL? {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }
}

struct CleanReport: Identifiable {
    enum Kind { case clean, restore, trash }
    let id = UUID()
    var title: String
    var kind: Kind = .clean
    var done: [(path: String, size: Int64)] = []
    var skipped: [(path: String, why: String)] = []
    var bytes: Int64 { done.reduce(0) { $0 + $1.size } }

    var headline: String {
        switch kind {
        case .clean: return "Moved \(done.count) items (\(Fmt.bytes(bytes))) to the Trash"
        case .restore: return done.isEmpty ? "Nothing was put back" : "Put back \(done.count) items"
        case .trash: return skipped.isEmpty ? "The Trash is empty" : "The Trash was not emptied"
        }
    }
}

struct HistoryItem: Codable {
    let original: String
    let trashed: String?
    let size: Int64
    var admin: Bool? = nil
    var area: String? = nil      // ScanArea raw value; nil in logs written before categories were kept
    var restored: Bool? = nil    // set by Restore for the items that came back
}

struct HistorySession: Codable {
    let date: Date
    var items: [HistoryItem]
}

/// Moves items to the Trash after checking each one again, and keeps a log so a cleanup can be put back.
final class Cleaner {
    let library: URL
    let systemRoots: [URL]
    let trasher: Trasher
    let historyDir: URL
    let adminRoots: [URL]
    let adminRunner: AdminRunner
    let trashDir: URL
    private let fm = FileManager.default

    /// System folders whose root-owned leftovers may be moved with the user's password.
    static let systemAdminRoots = ["Caches", "Logs", "Application Support", "Preferences", "LaunchAgents",
                                   "LaunchDaemons", "PrivilegedHelperTools"].map { FS.systemLibrary.appendingPathComponent($0) }

    /// Folders of ~/Library the app may ever touch; everything else (Mail, Keychains, Containers...) is off limits.
    static let libraryAreas: Set<String> = ["Caches", "Logs", "Application Support", "Preferences",
                                            "Saved Application State", "HTTPStorages", "WebKit", "Cookies",
                                            "LaunchAgents", "Developer"]

    init(library: URL = FS.library, systemRoots: [URL] = [FS.systemCaches, FS.systemLogs, URL(fileURLWithPath: "/cores")],
         trasher: Trasher = SystemTrasher(),
         historyDir: URL = FS.library.appendingPathComponent("Application Support/Relinquish/History"),
         adminRoots: [URL] = Cleaner.systemAdminRoots, adminRunner: AdminRunner = SystemAdminRunner(),
         trashDir: URL = FS.trash) {
        self.library = library
        self.systemRoots = systemRoots
        self.trasher = trasher
        self.historyDir = historyDir
        self.adminRoots = adminRoots
        self.adminRunner = adminRunner
        self.trashDir = trashDir
    }

    /// Why a root-owned item must not be moved, or nil when it may go (the root script checks open files).
    func adminRefusal(_ c: Candidate, index: AppIndex) -> String? {
        if c.tier == .blocked { return "it is in use" }
        let url = c.url.standardizedFileURL
        let fileName = c.url.lastPathComponent
        if fileName.contains("\n") || fileName.contains("\t") { return "its name has unusual characters" }
        let comps = url.pathComponents
        if comps.contains("..") { return "the path is not plain" }
        guard let root = adminRoots.first(where: { comps.starts(with: $0.standardizedFileURL.pathComponents) }) else {
            return "it is outside the system folders this app cleans"
        }
        let rel = Array(comps.dropFirst(root.standardizedFileURL.pathComponents.count))
        guard rel.count >= 1 else { return "it is a top folder" }
        if index.isApple(rel[0]) { return "it belongs to macOS" }
        if root.lastPathComponent == "Caches", Rules.isAppleCacheDenied(rel[0]) { return "it holds macOS account or sync state" }
        if !realParentInside(url, root) { return "the path passes through a link" }
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return "it is already gone" }
        if let owner = c.owner, index.isRunning(owner) { return "\(owner) is running now" }
        return nil
    }

    /// A free name in the Trash for an item, also unique within this batch.
    private func trashDestination(for name: String, taken: inout Set<String>) -> String {
        var candidate = trashDir.appendingPathComponent(name).path
        var n = 2
        while taken.contains(candidate) || fm.fileExists(atPath: candidate) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            candidate = trashDir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)").path
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// Why an item must not be moved right now, or nil when it may go.
    func refusal(_ c: Candidate, index: AppIndex, open: PathSet) -> String? {
        if c.tier == .blocked { return "it is in use" }
        let url = c.url.standardizedFileURL
        let comps = url.pathComponents
        if comps.contains("..") { return "the path is not plain" }

        let libComps = library.standardizedFileURL.pathComponents
        // developer folders in the home folder (checked first: Library/pnpm and Library/Android live under ~/Library)
        let home = library.deletingLastPathComponent()
        if let dev = DevTools.homeRoots.first(where: { comps.starts(with: home.appendingPathComponent($0.path).standardizedFileURL.pathComponents) }) {
            let root = home.appendingPathComponent(dev.path).standardizedFileURL
            guard c.area == .developer else { return "it is outside the folders this app cleans" }
            guard comps.count - root.pathComponents.count >= dev.minDepth else { return "it is a top folder" }
            if !realParentInside(url, root) { return "the path passes through a link" }
        } else if comps.starts(with: libComps) {
            let rel = Array(comps.dropFirst(libComps.count))
            guard rel.count >= 2, Cleaner.libraryAreas.contains(rel[0]) else { return "it is outside the folders this app cleans" }
            let appleAllowed: Set<ScanArea> = [.systemCaches, .systemLogs, .developer]
            if !appleAllowed.contains(c.area), index.isApple(rel[1]) { return "it belongs to macOS" }
            if c.area == .systemCaches, Rules.isAppleCacheDenied(rel[1]) { return "it holds macOS account or sync state" }
            if !realParentInside(url, library) { return "the path passes through a link" }
        } else if let root = systemRoots.first(where: { comps.starts(with: $0.standardizedFileURL.pathComponents) }) {
            guard comps.count > root.standardizedFileURL.pathComponents.count else { return "it is a top folder" }
            if !realParentInside(url, root) { return "the path passes through a link" }
            if !FS.canMove(url) { return "it needs administrator rights" }
        } else {
            return "it is outside the folders this app cleans"
        }

        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return "it is already gone" }
        if let owner = c.owner, index.isRunning(owner) { return "\(owner) is running now" }
        if open.anyInside(url.path) || index.processes.anyInside(url.path) { return "files inside are in use" }
        return nil
    }

    private func realParentInside(_ url: URL, _ root: URL) -> Bool {
        let parent = (url.deletingLastPathComponent().path as NSString).resolvingSymlinksInPath
        let r = (root.path as NSString).resolvingSymlinksInPath
        return parent == r || parent.hasPrefix(r + "/")
    }

    func clean(_ items: [Candidate], index: AppIndex, open: PathSet) -> CleanReport {
        var report = CleanReport(title: "Cleanup finished")
        var log: [HistoryItem] = []
        var adminBatch: [(Candidate, String)] = []
        var taken = Set<String>()
        for c in items where c.admin {
            if let why = adminRefusal(c, index: index) {
                report.skipped.append((c.displayPath, why))
            } else {
                adminBatch.append((c, trashDestination(for: c.url.lastPathComponent, taken: &taken)))
            }
        }
        if !adminBatch.isEmpty {
            let script = AdminScript.move(adminBatch.map { (from: $0.0.url.path, to: $0.1) })
            let r = adminRunner.run(script, prompt: "Relinquish wants to move \(adminBatch.count) system-wide items to your Trash.")
            let status = AdminScript.parse(r.output ?? "")
            for (c, dest) in adminBatch {
                if let err = r.error {
                    report.skipped.append((c.displayPath, err))
                } else if status[c.url.path] == "ok" {
                    report.done.append((c.displayPath, c.size))
                    log.append(HistoryItem(original: c.url.path, trashed: dest, size: c.size, admin: true, area: c.area.rawValue))
                } else {
                    report.skipped.append((c.displayPath, AdminScript.explain(status[c.url.path])))
                }
            }
        }
        for c in items where !c.admin {
            if let why = refusal(c, index: index, open: open) {
                report.skipped.append((c.displayPath, why))
                continue
            }
            do {
                let landed = try trasher.trash(c.url)
                report.done.append((c.displayPath, c.size))
                log.append(HistoryItem(original: c.url.path, trashed: landed?.path, size: c.size, area: c.area.rawValue))
            } catch {
                report.skipped.append((c.displayPath, error.localizedDescription))
            }
        }
        if !log.isEmpty { saveHistory(HistorySession(date: Date(), items: log)) }
        return report
    }

    // MARK: - History and restore

    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private func saveHistory(_ s: HistorySession) {
        try? fm.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        if let data = try? Cleaner.encoder.encode(s) {
            try? data.write(to: historyDir.appendingPathComponent(f.string(from: s.date) + ".json"))
        }
    }

    private func lastSessionFile() -> URL? {
        let files = (try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".restored.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    var canRestore: Bool { lastSessionFile() != nil }

    /// Puts the items of the most recent cleanup back where they were.
    func restoreLast() -> CleanReport {
        var report = CleanReport(title: "Restore finished", kind: .restore)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let file = lastSessionFile(), let data = try? Data(contentsOf: file),
              var s = try? dec.decode(HistorySession.self, from: data) else {
            report.title = "Nothing to restore"
            return report
        }
        var back = Set<String>()
        var adminPairs: [(from: String, to: String)] = []
        for item in s.items where item.admin == true {
            let shown = Fmt.tilde(item.original)
            guard let trashed = item.trashed, fm.fileExists(atPath: trashed) else {
                report.skipped.append((shown, "it is no longer in the Trash")); continue
            }
            adminPairs.append((from: trashed, to: item.original))
        }
        if !adminPairs.isEmpty {
            let r = adminRunner.run(AdminScript.move(adminPairs),
                                    prompt: "Relinquish wants to put \(adminPairs.count) system-wide items back.")
            let status = AdminScript.parse(r.output ?? "")
            for p in adminPairs {
                let shown = Fmt.tilde(p.to)
                if let err = r.error { report.skipped.append((shown, err)) }
                else if status[p.from] == "ok" {
                    back.insert(p.to)
                    report.done.append((shown, s.items.first { $0.original == p.to }?.size ?? 0))
                }
                else { report.skipped.append((shown, status[p.from] == "exists" ? "something new already exists at that path" : AdminScript.explain(status[p.from]))) }
            }
        }
        for item in s.items where item.admin != true {
            let shown = Fmt.tilde(item.original)
            guard let trashed = item.trashed, fm.fileExists(atPath: trashed) else {
                report.skipped.append((shown, "it is no longer in the Trash"))
                continue
            }
            if fm.fileExists(atPath: item.original) {
                report.skipped.append((shown, "something new already exists at that path"))
                continue
            }
            do {
                let dest = URL(fileURLWithPath: item.original)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: trashed), to: dest)
                back.insert(item.original)
                report.done.append((shown, item.size))
            } catch {
                report.skipped.append((shown, error.localizedDescription))
            }
        }
        // keep the log, flagging what came back, so Space Recovered stays exact
        for i in s.items.indices where back.contains(s.items[i].original) { s.items[i].restored = true }
        let done = file.deletingPathExtension().appendingPathExtension("restored.json")
        if let data = try? Cleaner.encoder.encode(s), (try? data.write(to: done)) != nil {
            try? fm.removeItem(at: file)
        } else {
            try? fm.moveItem(at: file, to: done)
        }
        return report
    }

    /// After the Trash is emptied nothing can be put back: retire every pending log.
    func retireHistory() {
        let files = (try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasSuffix(".restored.json")
            && !f.lastPathComponent.hasSuffix(".emptied.json") {
            try? fm.moveItem(at: f, to: f.deletingPathExtension().appendingPathExtension("emptied.json"))
        }
    }
}

/// The user's Trash: size and Empty Trash. Emptying goes through Finder so locked items and
/// the Trash folders on other volumes are handled the way Finder does it.
struct TrashBin {
    let dir: URL
    let useFinder: Bool

    static let user = TrashBin(dir: FS.trash, useFinder: true)

    /// nil when macOS privacy protection hides the Trash from this app.
    func size() -> Int64? { FS.size(of: dir) }

    func itemCount() -> Int? {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0 != ".DS_Store" }.count
    }

    /// Permanently deletes everything in the Trash. Returns an error message, or nil on success.
    func empty() -> String? {
        if useFinder {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            guard let err = err else { return nil }
            if let n = err[NSAppleScript.errorNumber] as? Int, n == -1743 {
                return "macOS did not let Relinquish control Finder. Allow it in System Settings → Privacy & Security → Automation, or empty the Trash from Finder."
            }
            return (err[NSAppleScript.errorMessage] as? String) ?? "Finder could not empty the Trash."
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return "The Trash cannot be read." }
        var failed = 0
        for n in names {
            do { try fm.removeItem(at: dir.appendingPathComponent(n)) } catch { failed += 1 }
        }
        return failed == 0 ? nil : "\(failed) items could not be deleted."
    }
}
