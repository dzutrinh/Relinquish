import Foundation

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

enum Shell {
    /// Runs a tool and returns its stdout ("" on failure). stderr is discarded.
    static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum FS {
    static let home = URL(fileURLWithPath: NSHomeDirectory())
    static let library = home.appendingPathComponent("Library")
    static let trash = home.appendingPathComponent(".Trash")
    static let systemCaches = URL(fileURLWithPath: "/Library/Caches")
    static let systemLogs = URL(fileURLWithPath: "/Library/Logs")
    static let systemLibrary = URL(fileURLWithPath: "/Library")

    /// Everywhere a candidate can live; lsof results are kept only under these.
    static var openFileRoots: [String] {
        [library.path, systemCaches.path, systemLogs.path, "/cores"] + DevTools.homeRoots.map { home.appendingPathComponent($0.path).path }
    }

    /// Allocated size in bytes, never following symbolic links; nil when unreadable.
    static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        let top: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let v = try? url.resourceValues(forKeys: top) else { return nil }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        guard (try? fm.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in e {
                if let r = try? f.resourceValues(forKeys: Set(keys)), r.isRegularFile == true {
                    total += Int64(r.totalFileAllocatedSize ?? r.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    /// True when the tree holds an app bundle or a Mach-O executable (program files, not settings).
    static func containsProgram(_ url: URL, limit: Int = 20000) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true }) else { return false }
        var seen = 0
        for case let f as URL in e {
            seen += 1
            if seen > limit { return false }
            if f.pathExtension == "app" { return true }
            guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  FileManager.default.isExecutableFile(atPath: f.path),
                  let h = FileHandle(forReadingAtPath: f.path) else { continue }
            let magic = h.readData(ofLength: 4)
            try? h.close()
            if [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
                Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca])].contains(magic) { return true }
        }
        return false
    }

    /// Moving an item needs write access to its parent and, for folders, to the folder itself.
    static func canMove(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: url.deletingLastPathComponent().path) else { return false }
        if isDirectory(url) && !fm.isWritableFile(atPath: url.path) { return false }
        return true
    }
}

/// Version-named folders ("2.1.295", "46.3.1.34493_uuid", "v1.2") and name-version siblings ("tool-2.96.0").
enum Version {
    /// Leading version numbers when the whole name is a version (optionally followed by -, _, + or . and a tag).
    static func pure(_ s: String) -> [Int]? {
        var t = Substring(s)
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        var run = t.prefix(while: { $0.isASCII && ($0.isNumber || $0 == ".") })
        while run.hasSuffix(".") { run = run.dropLast() }
        let parts = run.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 }) else { return nil }
        if let c = t.dropFirst(run.count).first, !"-_+.".contains(c) { return nil }
        return parts.map { Int($0)! }
    }

    /// Splits "copilot-desktop-gh-2.96.0" into ("copilot-desktop-gh", [2, 96, 0]).
    static func splitSuffix(_ s: String) -> (base: String, version: [Int])? {
        var idx = s.endIndex
        while let sep = s[..<idx].lastIndex(where: { $0 == "-" || $0 == "_" }) {
            let tail = String(s[s.index(after: sep)...])
            if let v = pure(tail), !tail.contains(where: { $0.isLetter && $0 != "v" && $0 != "V" }) {
                let base = String(s[..<sep])
                if !base.isEmpty { return (base, v) }
            }
            idx = sep
        }
        return nil
    }

    static func less(_ a: [Int], _ b: [Int]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }
}

enum Tokens {
    static let stop: Set<String> = [
        "com", "org", "net", "app", "apps", "dev", "info", "biz", "edu", "gov", "pro", "xyz", "inc", "ltd", "llc",
        "mac", "macos", "osx", "desktop", "helper", "helpers", "agent", "client", "service", "services", "launcher",
        "update", "updater", "updates", "the", "and", "for", "plus", "lite", "free", "studio", "software", "systems",
        "team", "group", "shared", "support", "data", "cache", "caches", "files", "file", "tool", "tools",
        "settings", "preferences", "plugin", "plugins", "extension", "extensions", "framework", "kit", "core",
        "apple", "beta", "stable", "release", "install", "installer", "setup", "renderer", "plist", "savedstate",
        "binarycookies", "logs", "log", "storage", "web", "user", "default", "main", "application", "safe",
    ]

    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func of(_ s: String) -> Set<String> {
        var out = Set<String>()
        func add(_ t: String) {
            let t = t.lowercased()
            if t.count >= 3, !stop.contains(t), t.contains(where: { $0.isLetter }) { out.insert(t) }
        }
        for w in s.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let word = String(w)
            add(word)
            for part in camelParts(word) where part.count >= 4 { add(part) }
        }
        return out
    }

    private static func camelParts(_ w: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        for ch in w {
            if ch.isUppercase, let last = cur.last, last.isLowercase { parts.append(cur); cur = "" }
            cur.append(ch)
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.count > 1 ? parts : []
    }
}

/// Sorted absolute paths with a fast "is anything inside this folder" query.
struct PathSet {
    let paths: [String]

    init(_ paths: [String]) { self.paths = paths.sorted() }

    func anyInside(_ p: String) -> Bool {
        var lo = 0, hi = paths.count
        while lo < hi {
            let m = (lo + hi) / 2
            if paths[m] < p { lo = m + 1 } else { hi = m }
        }
        var i = lo
        while i < paths.count && paths[i].hasPrefix(p) {
            if paths[i] == p || paths[i].hasPrefix(p + "/") { return true }
            i += 1
        }
        return false
    }

    /// Files currently open by this user's processes (lsof), limited to the given roots.
    static func openFiles(under roots: [String]) -> PathSet {
        let out = Shell.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-Fn", "-u", String(getuid())])
        var keep: [String] = []
        for line in out.split(separator: "\n") where line.hasPrefix("n/") {
            let p = String(line.dropFirst())
            if roots.contains(where: { p.hasPrefix($0 + "/") }) { keep.append(p) }
        }
        return PathSet(keep)
    }
}
