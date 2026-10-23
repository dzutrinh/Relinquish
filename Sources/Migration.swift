import Foundation

/// One-time move of what the app kept under its old name, "Library Cleaner":
/// saved scan areas, first-run date and cleanup logs (so Restore and Space Recovered keep working).
/// The few preference calls the migration needs; UserDefaults in the app, a dictionary in the self-test.
protocol PrefStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func bool(forKey key: String) -> Bool
}

extension UserDefaults: PrefStore {}

final class MemoryPrefs: PrefStore {
    var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}

enum Migration {
    static let oldDomain = "app.librarycleaner.LibraryCleaner"
    static let doneKey = "migratedFromLibraryCleaner"

    static func run(defaults d: PrefStore = UserDefaults.standard, old: PrefStore? = UserDefaults(suiteName: oldDomain),
                    oldHistory: URL = FS.library.appendingPathComponent("Application Support/LibraryCleaner/History"),
                    newHistory: URL) {
        guard !d.bool(forKey: doneKey) else { return }
        let fm = FileManager.default
        for key in ["scanAreas", "firstRun"] where d.object(forKey: key) == nil {
            if let v = old?.object(forKey: key) { d.set(v, forKey: key) }
        }
        if let files = try? fm.contentsOfDirectory(at: oldHistory, includingPropertiesForKeys: nil), !files.isEmpty {
            try? fm.createDirectory(at: newHistory, withIntermediateDirectories: true)
            for f in files {
                let dest = newHistory.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: f, to: dest) }   // never overwrite
            }
        }
        // the old folders go only when nothing is left in them
        for dir in [oldHistory, oldHistory.deletingLastPathComponent()] {
            if let left = try? fm.contentsOfDirectory(atPath: dir.path), left.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
        d.set(true, forKey: doneKey)
    }
}
