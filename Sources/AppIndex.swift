import AppKit

/// What is installed, what is running and what belongs to macOS. Every leftover decision asks this index.
final class AppIndex {
    enum Owner { case strong, weak, vendor, none }

    private(set) var ids = Set<String>()          // lowercased bundle ids of every known bundle
    private(set) var vendors = Set<String>()      // "com.vendor" of third-party bundles
    private(set) var tokens = Set<String>()       // name tokens of third-party bundles and tools
    private(set) var names = Set<String>()        // normalized full names (system bundles included)
    private(set) var runIDs = Set<String>()
    private(set) var runNames = Set<String>()     // normalized names of every running process
    private(set) var runTokens = Set<String>()    // tokens of running third-party apps and processes
    private(set) var processes = PathSet([])      // executable paths of running processes
    private(set) var systemNames = Set<String>()  // macOS binaries, frameworks and services

    init() {}

    // MARK: - Building

    func addApp(id: String?, names ns: [String], system: Bool) {
        if let id = id?.lowercased(), !id.isEmpty {
            ids.insert(id)
            let c = id.split(separator: ".")
            if !system {
                if c.count >= 3 { vendors.insert(c[0] + "." + c[1]) }
                tokens.formUnion(Tokens.of(id))
            }
        }
        for n in ns {
            let norm = Tokens.normalize(n)
            if !norm.isEmpty { names.insert(norm) }
            if !system { tokens.formUnion(Tokens.of(n)) }
        }
    }

    func addRunning(id: String?, names ns: [String], system: Bool) {
        if let id = id?.lowercased(), !id.isEmpty {
            runIDs.insert(id)
            if !system { runTokens.formUnion(Tokens.of(id)) }
        }
        for n in ns {
            let norm = Tokens.normalize(n)
            if !norm.isEmpty { runNames.insert(norm) }
            if !system { runTokens.formUnion(Tokens.of(n)) }
        }
    }

    func setProcesses(_ paths: [String]) { processes = PathSet(paths) }
    func addSystemNames(_ ns: [String]) { for n in ns { systemNames.insert(Tokens.normalize(n)) } }

    // MARK: - Queries

    static func stripExt(_ name: String) -> String {
        for ext in [".plist", ".savedState", ".binarycookies", ".log"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    static let tlds: Set<String> = ["com", "org", "net", "io", "app", "ai", "co", "dev", "me", "tv", "us", "uk",
                                    "de", "fr", "jp", "cn", "info", "biz", "edu", "ru", "nl", "se", "ch", "it",
                                    "es", "ca", "au", "kr", "vn", "sh", "xyz", "eu", "pro", "cc", "is", "to", "ws"]

    static func isBundleID(_ name: String) -> Bool {
        let l = stripExt(name).lowercased()
        guard !l.contains(" ") else { return false }
        let c = l.split(separator: ".")
        return c.count >= 3 || (c.count == 2 && tlds.contains(String(c[0])))
    }

    func owner(of name: String) -> Owner {
        let base = AppIndex.stripExt(name)
        let l = base.lowercased()
        if ids.contains(l) || names.contains(Tokens.normalize(l)) { return .strong }
        if AppIndex.isBundleID(base) {
            if ids.contains(where: { $0.hasPrefix(l + ".") || l.hasPrefix($0 + ".") }) { return .strong }
            let c = l.split(separator: ".")
            if c.count >= 3, vendors.contains(c[0] + "." + c[1]) { return .vendor }
        }
        return Tokens.of(base).isDisjoint(with: tokens) ? .none : .weak
    }

    func isRunning(_ name: String) -> Bool {
        let base = AppIndex.stripExt(name)
        let l = base.lowercased()
        if runIDs.contains(where: { $0 == l || $0.hasPrefix(l + ".") || l.hasPrefix($0 + ".") }) { return true }
        if runNames.contains(Tokens.normalize(l)) { return true }
        // com.apple.callintelligenced -> is "callintelligenced" running?
        if let last = l.split(separator: ".").last, l.contains("."), runNames.contains(Tokens.normalize(String(last))) {
            return true
        }
        return !Tokens.of(base).isDisjoint(with: runTokens)
    }

    func isApple(_ name: String) -> Bool {
        let l = AppIndex.stripExt(name).lowercased()
        if Rules.applePrefixes.contains(where: { l.hasPrefix($0) }) { return true }
        let n = Tokens.normalize(l)
        let bare = Tokens.normalize((l as NSString).deletingPathExtension)   // "PhotosUpgrade.aapbz"
        if Rules.appleNames.contains(n) || systemNames.contains(n) { return true }
        if !bare.isEmpty, Rules.appleNames.contains(bare) || systemNames.contains(bare) { return true }
        // daemon-style names: "familycircled", "homeenergyd", "mbuseragent"
        if l.count >= 5, l.allSatisfy({ $0.isLetter && $0.isLowercase }),
           l.hasSuffix("d") || l.hasSuffix("agent"), owner(of: l) == .none { return true }
        return false
    }

    // MARK: - Live system

    static func live() -> AppIndex {
        let idx = AppIndex()
        let fm = FileManager.default
        let home = NSHomeDirectory()

        var bundles = Set<String>()
        for line in Shell.run("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"])
            .split(separator: "\n") { bundles.insert(String(line)) }
        let bundleExts: Set<String> = ["app", "prefPane", "bundle", "plugin", "appex", "component", "qlgenerator", "saver"]
        let dirs = ["/Applications", "/Applications/Utilities", home + "/Applications", "/System/Applications",
                    "/System/Applications/Utilities", "/Library/PreferencePanes", home + "/Library/PreferencePanes",
                    "/Library/Input Methods", home + "/Library/Input Methods", "/Library/Screen Savers",
                    "/Library/QuickLook", home + "/Library/QuickLook", "/Library/Audio/Plug-Ins/Components"]
        for d in dirs {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                let p = d + "/" + n
                let ext = (n as NSString).pathExtension
                if bundleExts.contains(ext) {
                    bundles.insert(p)
                } else if ext.isEmpty, d.hasSuffix("Applications") {   // vendor folders like /Applications/Adobe X
                    for m in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where m.hasSuffix(".app") {
                        bundles.insert(p + "/" + m)
                    }
                }
            }
        }
        for b in bundles where !b.contains("/.Trash/") {
            let info = NSDictionary(contentsOfFile: b + "/Contents/Info.plist") as? [String: Any]
            let id = info?["CFBundleIdentifier"] as? String
            var ns = ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"].compactMap { info?[$0] as? String }
            ns.append(((b as NSString).lastPathComponent as NSString).deletingPathExtension)
            let system = b.hasPrefix("/System/") || b.hasPrefix("/Library/Apple/")
                || (id?.lowercased().hasPrefix("com.apple.") ?? false)
            idx.addApp(id: id, names: ns, system: system)
        }

        // launchd jobs installed system-wide by third parties (drivers, helpers)
        for d in ["/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"] {
            for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] {
                let label = AppIndex.stripExt(n)
                idx.addApp(id: label, names: [], system: label.lowercased().hasPrefix("com.apple."))
            }
        }

        // command-line tools: exact names only, their tokens are too generic
        for d in ["/opt/homebrew/bin", "/opt/homebrew/Cellar", "/opt/homebrew/Caskroom", "/usr/local/bin",
                  home + "/.local/bin", home + "/.cargo/bin"] {
            let ns = (try? fm.contentsOfDirectory(atPath: d)) ?? []
            idx.addApp(id: nil, names: ns, system: true)
        }
        if fm.fileExists(atPath: "/opt/homebrew") || fm.fileExists(atPath: "/usr/local/Homebrew") {
            idx.addApp(id: nil, names: ["Homebrew"], system: false)
        }

        // macOS binaries, frameworks and core services
        for d in ["/usr/libexec", "/usr/sbin", "/usr/bin", "/bin", "/sbin", "/System/Library/CoreServices",
                  "/System/Library/PrivateFrameworks", "/System/Library/Frameworks", "/System/Library/ExtensionKit/Extensions"] {
            let ns = ((try? fm.contentsOfDirectory(atPath: d)) ?? []).map { ($0 as NSString).deletingPathExtension }
            idx.addSystemNames(ns)
        }

        for app in NSWorkspace.shared.runningApplications {
            let path = app.bundleURL?.path ?? ""
            let system = path.hasPrefix("/System/") || (app.bundleIdentifier?.hasPrefix("com.apple.") ?? false)
            idx.addRunning(id: app.bundleIdentifier,
                           names: [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 },
                           system: system)
        }
        var paths: [String] = []
        for line in Shell.run("/bin/ps", ["-axo", "comm="]).split(separator: "\n") {
            let p = line.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            paths.append(p)
            let system = Rules.systemExecutablePrefixes.contains { p.hasPrefix($0) } || !p.hasPrefix("/")
            idx.addRunning(id: nil, names: [(p as NSString).lastPathComponent], system: system)
        }
        idx.setProcesses(paths)
        return idx
    }
}
