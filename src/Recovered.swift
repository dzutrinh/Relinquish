import Foundation

/// Space recovered since the first run, read back from the cleanup logs.
struct RecoveredStats {
    enum State { case freed, inTrash, restored, partlyRestored }

    struct Session: Identifiable {
        let id: String           // log file name
        let date: Date
        let items: Int
        let freed: Int64
        let inTrash: Int64
        let restored: Int64
        let restoredItems: Int
        let admin: Int
        var state: State {
            if freed + inTrash == 0 { return .restored }
            if restored > 0 { return .partlyRestored }
            return inTrash > 0 ? .inTrash : .freed
        }
    }

    struct Category: Identifiable {
        let area: ScanArea
        var freed: Int64 = 0
        var inTrash: Int64 = 0
        var items = 0
        var id: String { area.rawValue }
        var total: Int64 { freed + inTrash }
    }

    var sessions: [Session] = []
    var categories: [Category] = []
    var freed: Int64 = 0
    var inTrash: Int64 = 0
    var restored: Int64 = 0
    var items = 0

    var total: Int64 { freed + inTrash }

    /// Freed = the Trash was emptied (by this app, or the item is no longer in the Trash).
    /// In Trash = still there, so the space comes back only when the Trash is emptied.
    static func load(from dir: URL, fm: FileManager = .default) -> RecoveredStats {
        var out = RecoveredStats()
        var cats: [ScanArea: Category] = [:]
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        for f in files {
            guard let data = try? Data(contentsOf: f), let s = try? dec.decode(HistorySession.self, from: data) else { continue }
            let name = f.lastPathComponent
            let emptied = name.hasSuffix(".emptied.json")
            let legacyRestored = name.hasSuffix(".restored.json") && !s.items.contains { $0.restored != nil }
            var freed: Int64 = 0, inTrash: Int64 = 0, restored: Int64 = 0, n = 0, admin = 0, back = 0
            for item in s.items {
                if legacyRestored || item.restored == true { restored += item.size; back += 1; continue }
                let stillThere = !emptied && (item.trashed.map { fm.fileExists(atPath: $0) } ?? false)
                let area = item.area.flatMap(ScanArea.init(rawValue:)) ?? RecoveredStats.inferArea(item.original)
                var cat = cats[area] ?? Category(area: area)
                if stillThere { inTrash += item.size; cat.inTrash += item.size } else { freed += item.size; cat.freed += item.size }
                cat.items += 1
                cats[area] = cat
                n += 1
                if item.admin == true { admin += 1 }
            }
            out.sessions.append(Session(id: name, date: s.date, items: n, freed: freed, inTrash: inTrash, restored: restored, restoredItems: back, admin: admin))
            out.freed += freed
            out.inTrash += inTrash
            out.restored += restored
            out.items += n
        }
        out.sessions.sort { $0.date > $1.date }
        out.categories = cats.values.filter { $0.items > 0 }.sorted { $0.total > $1.total }
        return out
    }

    /// Category for logs written before categories were kept, from the item's original path.
    static func inferArea(_ path: String) -> ScanArea {
        if path.hasPrefix("/Library/") { return .systemLeftovers }
        let lib = FS.library.path + "/"
        guard path.hasPrefix(lib) else { return .leftoverData }
        let rel = path.dropFirst(lib.count).split(separator: "/").map(String.init)
        guard let top = rel.first else { return .leftoverData }
        let name = rel.count > 1 ? rel[1] : ""
        let apple = Rules.applePrefixes.contains { name.lowercased().hasPrefix($0) }
            || Rules.appleNames.contains(Tokens.normalize((name as NSString).deletingPathExtension))
        switch top {
        case "Caches": return apple ? .systemCaches : .appCaches
        case "Logs": return apple || name == "DiagnosticReports" ? .systemLogs : .appLogs
        case "Preferences": return .leftoverSettings
        case "Saved Application State", "HTTPStorages", "WebKit", "Cookies": return .leftoverWeb
        case "LaunchAgents": return .launchAgents
        case "Developer": return .developer
        case "Application Support":
            guard let last = rel.last, rel.count > 2 else { return .leftoverData }
            if Rules.cacheFolderNames.contains(last) { return .appCaches }
            if Rules.logFolderNames.contains(last) { return .appLogs }
            if Version.pure(last) != nil { return .oldVersions }
            return .leftoverData
        default: return .leftoverData
        }
    }
}
