import Foundation

struct ScanResult {
    var candidates: [Candidate] = []
    var protectedCount = 0   // macOS items never offered
    var needsAdmin = 0       // system-wide items the user cannot move
    var unreadable = 0       // items macOS privacy protection hides from us
}

/// Read-only: walks the chosen areas and classifies what it finds. Never changes anything on disk.
final class Scanner {
    let library: URL
    let systemCaches: URL?
    let systemLogs: URL?
    let systemLibrary: URL?
    let cores: URL?
    var home: URL { library.deletingLastPathComponent() }
    let index: AppIndex
    let open: PathSet
    let areas: Set<ScanArea>
    private let fm = FileManager.default

    private var found: [String: Candidate] = [:]
    private var order: [String] = []
    private var result = ScanResult()

    init(index: AppIndex, open: PathSet, areas: Set<ScanArea>, library: URL = FS.library,
         systemCaches: URL? = FS.systemCaches, systemLogs: URL? = FS.systemLogs,
         systemLibrary: URL? = FS.systemLibrary, cores: URL? = URL(fileURLWithPath: "/cores")) {
        self.index = index
        self.open = open
        self.areas = areas
        self.library = library
        self.systemCaches = systemCaches
        self.systemLogs = systemLogs
        self.systemLibrary = systemLibrary
        self.cores = cores
    }

    /// progress(step, fraction): fraction runs 0...1 across the chosen phases, sizing last.
    func scan(progress: (String, Double) -> Void = { _, _ in }) -> ScanResult {
        var steps: [(String, () -> Void)] = []
        if areas.contains(.developer) {
            steps.append(("Xcode", scanDeveloper))
            steps.append(("Code editors", scanEditors))
            steps.append(("JetBrains IDEs", scanJetBrains))
            steps.append(("Build tool caches", scanBuildCaches))
        }
        if areas.contains(.oldVersions) { steps.append(("Old app versions", scanOldVersions)) }
        if areas.contains(.appCaches) { steps.append(("Cache folders in app data", scanAppDataFolders)) }
        if areas.contains(.appCaches) || areas.contains(.systemCaches) { steps.append(("Caches", scanCaches)) }
        if areas.contains(.appLogs) || areas.contains(.systemLogs) { steps.append(("Logs", scanLogs)) }
        if areas.contains(.systemCaches), let d = systemCaches { steps.append(("System caches", { self.scanSystemWide(d, area: .systemCaches) })) }
        if areas.contains(.systemLogs), let d = systemLogs { steps.append(("System logs", { self.scanSystemWide(d, area: .systemLogs) })) }
        if areas.contains(.leftoverSettings) { steps.append(("Leftover settings", scanSettings)) }
        if areas.contains(.leftoverWeb) { steps.append(("Leftover web data", scanWebData)) }
        if areas.contains(.leftoverData) { steps.append(("Leftover app data", scanAppData)) }
        if areas.contains(.launchAgents) { steps.append(("Login items", scanLaunchAgents)) }
        if areas.contains(.systemLeftovers), systemLibrary != nil { steps.append(("System-wide leftovers", scanSystemLeftovers)) }
        for (i, s) in steps.enumerated() {
            progress(s.0, 0.6 * Double(i) / Double(max(1, steps.count)))
            s.1()
        }
        finish { done in progress("Measuring sizes", 0.6 + 0.4 * done) }
        return result
    }

    // MARK: - Helpers

    /// Children built from names under `dir` itself: URL listings may resolve links (/var -> /private/var),
    /// and every path must stay comparable with the roots the cleaner checks against.
    private func children(_ dir: URL) -> [URL] {
        do {
            return try fm.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted()
                .map { dir.appendingPathComponent($0) }
        } catch let e as NSError {
            if e.code == NSFileReadNoPermissionError { result.unreadable += 1 }
            return []
        }
    }

    private func lib(_ rel: String) -> URL { library.appendingPathComponent(rel) }

    private func isOwn(_ name: String) -> Bool {
        let l = name.lowercased()
        return ["relinquish", "librarycleaner"].contains(l) || l.hasPrefix("app.relinquish") || l.hasPrefix("app.librarycleaner")
    }

    private func add(_ url: URL, _ area: ScanArea, _ tier: Tier, _ reason: String, owner: String? = nil, admin: Bool = false,
                     label: String? = nil, app: String? = nil) {
        let path = url.path
        guard found[path] == nil else { return }
        var c = Candidate(url: url, area: area, tier: tier, reason: reason, owner: owner, admin: admin, label: label, app: app)
        if tier != .blocked, open.anyInside(path) || index.processes.anyInside(path) {
            c.tier = .blocked
            c.reason = "Files inside are open in a running program. " + reason
        }
        found[path] = c
        order.append(path)
    }

    /// Cache-type items: blocked while the owning app runs.
    private func addCache(_ url: URL, _ area: ScanArea, owner: String, reason: String) {
        if index.isRunning(owner) {
            add(url, area, .blocked, "\(owner) is running. Quit it and scan again to clean this.", owner: owner)
        } else {
            add(url, area, .safe, reason, owner: owner)
        }
    }

    // MARK: - Areas

    private func scanDeveloper() {
        let xcodeRunning = index.runIDs.contains("com.apple.dt.xcode")
        let derived = lib("Developer/Xcode/DerivedData")
        if fm.fileExists(atPath: derived.path) {
            add(derived, .developer, xcodeRunning ? .blocked : .safe,
                xcodeRunning ? "Xcode is running. Quit it to clean build products." : "Xcode build products; rebuilt on the next build.",
                owner: "com.apple.dt.Xcode")
        }
        let previews = lib("Developer/Xcode/UserData/Previews")
        if fm.fileExists(atPath: previews.path) {
            add(previews, .developer, xcodeRunning ? .blocked : .safe, "SwiftUI preview builds; rebuilt when needed.",
                owner: "com.apple.dt.Xcode")
        }
        let sim = lib("Developer/CoreSimulator/Caches")
        if fm.fileExists(atPath: sim.path) {
            let running = index.runIDs.contains("com.apple.iphonesimulator")
            add(sim, .developer, running ? .blocked : .safe,
                running ? "Simulator is running." : "Simulator caches; rebuilt when needed.", owner: "com.apple.iphonesimulator")
        }
        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            for d in children(lib("Developer/Xcode/\(platform) DeviceSupport")) {
                add(d, .developer, .review, "\(platform) debug symbols for one device OS version; Xcode downloads them again when that device connects.")
            }
        }
        let docs = lib("Developer/Xcode/DocumentationCache")
        if fm.fileExists(atPath: docs.path) {
            add(docs, .developer, xcodeRunning ? .blocked : .safe, "Xcode documentation cache; rebuilt when needed.", owner: "com.apple.dt.Xcode")
        }
        let archives = lib("Developer/Xcode/Archives")
        if fm.fileExists(atPath: archives.path) {
            add(archives, .developer, .review, "App archives; needed to read crash reports of builds you shipped.")
        }
    }

    private func scanOldVersions() {
        for top in children(lib("Application Support")) where FS.isDirectory(top) {
            let name = top.lastPathComponent
            if index.isApple(name) || isOwn(name) { continue }
            var queue: [(URL, Int)] = [(top, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 3000 {
                let (dir, depth) = queue.removeFirst()
                visited += 1
                var versioned: [(URL, [Int])] = []
                for c in children(dir) where FS.isDirectory(c) && !FS.isPackage(c) {
                    if let v = Version.pure(c.lastPathComponent) {
                        versioned.append((c, v))
                    } else if depth < 3 {
                        queue.append((c, depth + 1))
                    }
                }
                guard versioned.count >= 2,
                      let newest = versioned.max(by: { Version.less($0.1, $1.1) }) else { continue }
                for (u, v) in versioned where v != newest.1 {
                    let current = newest.0.lastPathComponent
                    if FS.containsProgram(u) {
                        add(u, .oldVersions, .safe,
                            "Old program version left behind by an updater; \(current) is the current one.")
                    } else {
                        add(u, .oldVersions, .review,
                            "Older version folder (\(current) is newest). It may hold settings for that version.")
                    }
                }
            }
        }
    }

    private func scanAppDataFolders() {
        for top in children(lib("Application Support")) where FS.isDirectory(top) && !FS.isPackage(top) {
            let owner = top.lastPathComponent
            if index.isApple(owner) || isOwn(owner) { continue }
            for l1 in children(top) where FS.isDirectory(l1) && !FS.isPackage(l1) {
                if Rules.cacheFolderNames.contains(l1.lastPathComponent) {
                    addCache(l1, .appCaches, owner: owner, reason: "Cache folder of \(owner); rebuilt when needed.")
                    continue
                }
                if Rules.logFolderNames.contains(l1.lastPathComponent), areas.contains(.appLogs) {
                    addCache(l1, .appLogs, owner: owner, reason: "Log files of \(owner).")
                    continue
                }
                for l2 in children(l1) where Rules.cacheFolderNames.contains(l2.lastPathComponent) && FS.isDirectory(l2) {
                    addCache(l2, .appCaches, owner: owner, reason: "Cache folder of \(owner); rebuilt when needed.")
                }
            }
        }
    }

    private func scanCaches() {
        let items = children(lib("Caches"))
        // "tool-2.96.0" next to "tool-2.101.0": the older copy is dead weight
        var groups: [String: [(URL, [Int])]] = [:]
        for u in items {
            if let s = Version.splitSuffix(u.lastPathComponent) { groups[s.base.lowercased(), default: []].append((u, s.version)) }
        }
        var older: [String: String] = [:]
        for (_, g) in groups where g.count >= 2 {
            guard let newest = g.max(by: { Version.less($0.1, $1.1) }) else { continue }
            for (u, v) in g where v != newest.1 { older[u.path] = newest.0.lastPathComponent }
        }

        for u in items {
            let name = u.lastPathComponent
            if isOwn(name) { continue }
            if areas.contains(.developer) && name == "JetBrains" { continue }
            if index.isApple(name) {
                guard areas.contains(.systemCaches), !Rules.isAppleCacheDenied(name) else { result.protectedCount += 1; continue }
                addCache(u, .systemCaches, owner: name, reason: "macOS cache; rebuilt when needed.")
                continue
            }
            guard areas.contains(.appCaches) else { continue }
            if let newest = older[u.path] {
                add(u, .appCaches, .safe, "Older cached version; \(newest) is the current one.")
            } else {
                let gone = index.owner(of: name) == .none
                addCache(u, .appCaches, owner: name,
                         reason: gone ? "Cache of an app that is no longer installed." : "Cache; the app rebuilds it when needed.")
            }
        }
    }

    private func scanLogs() {
        for u in children(lib("Logs")) {
            let name = u.lastPathComponent
            if isOwn(name) { continue }
            if areas.contains(.developer) && name == "JetBrains" { continue }
            if name == "DiagnosticReports" || name == "CrashReporter" {
                if areas.contains(.systemLogs) {
                    add(u, .systemLogs, .review, "Crash reports; keep them while you are tracking down a crash.")
                }
            } else if index.isApple(name) {
                if areas.contains(.systemLogs) { addCache(u, .systemLogs, owner: name, reason: "macOS log files.") }
            } else if areas.contains(.appLogs) {
                let gone = index.owner(of: name) == .none
                addCache(u, .appLogs, owner: name,
                         reason: gone ? "Logs of an app that is no longer installed." : "Log files; nothing reads them back.")
            }
        }
    }

    /// /Library/Caches and /Library/Logs: only what this user may move without administrator rights.
    private func scanSystemWide(_ dir: URL, area: ScanArea) {
        for u in children(dir) {
            let name = u.lastPathComponent
            if area == .systemCaches && Rules.isAppleCacheDenied(name) { result.protectedCount += 1; continue }
            guard FS.canMove(u) else {
                if areas.contains(.systemLeftovers), !index.isApple(name), index.owner(of: name) == .none {
                    add(u, .systemLeftovers, .safe, "System-wide \(area == .systemCaches ? "cache" : "logs") of an app that is no longer installed.",
                        owner: name, admin: true)
                } else {
                    result.needsAdmin += 1
                }
                continue
            }
            if name == "DiagnosticReports" {
                add(u, area, .review, "System crash reports; keep them while you are tracking down a crash.")
            } else {
                addCache(u, area, owner: name,
                         reason: area == .systemCaches ? "System-wide cache; rebuilt when needed." : "System-wide log files.")
            }
        }
    }

    /// Leftover check shared by settings and web data: bundle-id names with no app are safe, the rest need review.
    private func leftover(_ u: URL, name: String, area: ScanArea, what: String) {
        if index.isApple(name) || isOwn(name) { result.protectedCount += 1; return }
        switch index.owner(of: name) {
        case .strong, .weak:
            return
        case .vendor:
            add(u, area, .review, "\(what) of an app that seems removed; the same vendor still has other apps installed.")
        case .none:
            if AppIndex.isBundleID(name) {
                add(u, area, .safe, "\(what) of an app that is no longer installed.")
            } else {
                add(u, area, .review, "Looks like leftover \(what.lowercased()); no installed app matches the name.")
            }
        }
    }

    private func scanSettings() {
        for u in children(lib("Preferences")) where u.lastPathComponent != "ByHost" {
            leftover(u, name: u.lastPathComponent, area: .leftoverSettings, what: "Settings")
        }
        // ByHost files are "<bundle id>.<hardware UUID>.plist"
        for u in children(lib("Preferences/ByHost")) {
            var name = AppIndex.stripExt(u.lastPathComponent)
            if let dot = name.lastIndex(of: "."), name[name.index(after: dot)...].count >= 12,
               name[name.index(after: dot)...].allSatisfy({ $0.isHexDigit || $0 == "-" }) {
                name = String(name[..<dot])
            }
            leftover(u, name: name, area: .leftoverSettings, what: "Settings")
        }
    }

    private func scanWebData() {
        for u in children(lib("Saved Application State")) where u.pathExtension == "savedState" {
            leftover(u, name: u.lastPathComponent, area: .leftoverWeb, what: "Saved window state")
        }
        for dir in ["HTTPStorages", "WebKit", "Cookies"] {
            for u in children(lib(dir)) {
                leftover(u, name: u.lastPathComponent, area: .leftoverWeb, what: "Web data")
            }
        }
    }

    private func scanAppData() {
        for u in children(lib("Application Support")) {
            let name = u.lastPathComponent
            if index.isApple(name) || isOwn(name) { result.protectedCount += 1; continue }
            switch index.owner(of: name) {
            case .strong, .weak:
                continue
            case .vendor, .none:
                add(u, .leftoverData, .review,
                    "No installed app matches this folder. Check it holds nothing you need (saves, documents, licences).")
            }
        }
    }

    private func scanLaunchAgents() {
        for u in children(lib("LaunchAgents")) where u.pathExtension == "plist" {
            if index.isApple(u.lastPathComponent) { continue }
            guard let job = NSDictionary(contentsOf: u) as? [String: Any] else { continue }
            let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first ?? ""
            guard program.hasPrefix("/") || program.hasPrefix("~") else { continue }
            let path = (program as NSString).expandingTildeInPath
            if !fm.fileExists(atPath: path) {
                add(u, .launchAgents, .review, "Starts \(Fmt.tilde(path)), which no longer exists.")
            }
        }
    }

    /// True when an Apple installer package put this path on disk (pkgutil receipt).
    private func installedByApple(_ u: URL) -> Bool {
        Shell.run("/usr/sbin/pkgutil", ["--file-info", u.path]).split(separator: "\n")
            .contains { $0.hasPrefix("pkgid: com.apple.") }
    }

    // MARK: - Developer tools

    private func homeURL(_ rel: String) -> URL { home.appendingPathComponent(rel) }

    private func isNonEmpty(_ u: URL) -> Bool {
        guard FS.isDirectory(u) else { return fm.fileExists(atPath: u.path) }
        return !((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0 != ".DS_Store" }.isEmpty
    }

    /// VS Code and forks: stale workspace state, old compiled-code caches, unused extension versions.
    private func scanEditors() {
        for e in DevTools.editors {
            let support = lib("Application Support/\(e.support)")
            let installed = index.owner(of: e.name) != .none || index.owner(of: e.process) != .none
            if fm.fileExists(atPath: support.path) {
                // workspace state whose project folder is gone
                for w in children(support.appendingPathComponent("User/workspaceStorage")) {
                    guard let data = try? Data(contentsOf: w.appendingPathComponent("workspace.json")),
                          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let uri = (j["folder"] as? String) ?? (j["workspace"] as? String), uri.hasPrefix("file://"),
                          let path = URL(string: uri)?.path, !path.isEmpty else { continue }
                    guard !fm.fileExists(atPath: path) else { continue }
                    let comps = URL(fileURLWithPath: path).pathComponents
                    if comps.count > 2, comps[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/" + comps[2]) { continue }  // drive not connected
                    if fm.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) {
                        add(w, .developer, .safe, "\(e.name) state for \(Fmt.tilde(path)), a project folder that no longer exists.",
                            label: "\((path as NSString).lastPathComponent) — workspace state", app: e.name)
                    } else {
                        add(w, .developer, .review, "\(e.name) state for \(Fmt.tilde(path)). Neither it nor its parent folder exists; it may be on a drive or cloud folder that isn't available right now.",
                            label: "\((path as NSString).lastPathComponent) — workspace state", app: e.name)
                    }
                }
                // compiled-code caches of older editor builds (one folder per build)
                let builds = children(support.appendingPathComponent("CachedData")).filter { FS.isDirectory($0) }
                let dated = builds.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
                if let newest = dated.max(by: { $0.1 < $1.1 }) {
                    for (b, _) in dated where b != newest.0 {
                        add(b, .developer, .safe, "Compiled code cache of an older \(e.name) build.", owner: e.process,
                            label: "Old build cache \(b.lastPathComponent.prefix(8))", app: e.name)
                    }
                }
                for runtime in ["chatDictationRuntime"] {
                    let r = support.appendingPathComponent(runtime)
                    if isNonEmpty(r) {
                        add(r, .developer, .review, "\(e.name) dictation runtime; downloaded again if you use dictation.", owner: e.process,
                            label: "Dictation runtime", app: e.name)
                    }
                }
            }
            // extension versions the editor no longer uses
            let ext = homeURL("\(e.extDir)/extensions")
            let folders = children(ext).filter { FS.isDirectory($0) }
            guard !folders.isEmpty else { continue }
            if !installed {
                add(ext, .developer, .review, "Extensions of \(e.name), which is no longer installed.", label: "\(e.name) extensions")
                continue
            }
            var used: Set<String>?
            if let data = try? Data(contentsOf: ext.appendingPathComponent("extensions.json")),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                used = Set(list.compactMap { $0["relativeLocation"] as? String })
            }
            var obsolete = Set<String>()
            if let data = try? Data(contentsOf: ext.appendingPathComponent(".obsolete")),
               let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obsolete = Set(o.keys)
            }
            for f in folders {
                let name = f.lastPathComponent
                if obsolete.contains(name) {
                    add(f, .developer, .safe, "Extension version \(e.name) marked as replaced.", owner: e.process, app: e.name)
                } else if let used = used, !used.isEmpty, !used.contains(name) {
                    add(f, .developer, .safe, "Extension version \(e.name) no longer uses (a newer one is installed).", owner: e.process, app: e.name)
                }
            }
        }
        // Sublime Text index and Zed's downloaded tools
        for s in ["Sublime Text", "Sublime Text 3"] {
            let idx = lib("Application Support/\(s)/Index")
            if isNonEmpty(idx) { addCache(idx, .developer, owner: "Sublime Text", reason: "Sublime Text symbol index; rebuilt when needed.") }
        }
        for z in ["node", "languages", "copilot", "prettier"] {
            let d = lib("Application Support/Zed/\(z)")
            if isNonEmpty(d) { add(d, .developer, .review, "Tools Zed downloaded (\(z)); fetched again when needed.", owner: "Zed") }
        }
    }

    /// JetBrains IDEs and Android Studio keep one folder per version; older versions are left behind on upgrade.
    private func scanJetBrains() {
        let places: [(top: String, vendor: String, settings: Bool)] = [
            ("Caches", "JetBrains", false), ("Logs", "JetBrains", false), ("Application Support", "JetBrains", true),
            ("Caches", "Google", false), ("Logs", "Google", false), ("Application Support", "Google", true),
        ]
        var found: [(url: URL, top: String, settings: Bool, product: String, version: [Int])] = []
        for p in places {
            for u in children(lib("\(p.top)/\(p.vendor)")) where FS.isDirectory(u) {
                guard let v = DevTools.ideVersion(u.lastPathComponent), DevTools.jetBrainsProcess[v.product] != nil else { continue }
                found.append((u, p.top, p.settings, v.product, v.version))
            }
        }
        // the current version of a product is the newest seen in any of the three folders
        var current: [String: [Int]] = [:]
        for f in found where current[f.product].map({ Version.less($0, f.version) }) ?? true { current[f.product] = f.version }
        for f in found {
            let process = DevTools.jetBrainsProcess[f.product] ?? f.product
            let now = f.product + (current[f.product] ?? []).map(String.init).joined(separator: ".")
            if f.version != current[f.product] {
                if f.settings {
                    add(f.url, .developer, .review, "Settings and plug-ins of an older \(f.product) version; \(now) is current.", owner: process)
                } else {
                    add(f.url, .developer, .safe, "\(f.top == "Logs" ? "Logs" : "Caches") of an older \(f.product) version; \(now) is current.", owner: process)
                }
            } else if f.top == "Caches" {
                if index.isRunning(process) {
                    add(f.url, .developer, .blocked, "\(f.product) is running. Quit it and scan again to clean this.", owner: process)
                } else {
                    add(f.url, .developer, .review, "Caches of \(now); rebuilt next time, but re-indexing your projects takes a while.", owner: process)
                }
            }
        }
    }

    /// Package manager and build caches in the home folder, emulators, ~/.cache and core dumps.
    private func scanBuildCaches() {
        for c in DevTools.homeCaches {
            let u = homeURL(c.path)
            if isNonEmpty(u) { add(u, .developer, c.tier, c.reason) }
        }
        // Gradle keeps every wrapper version it ever downloaded
        let dists = children(homeURL(".gradle/wrapper/dists")).filter { FS.isDirectory($0) }
        let gradle = dists.compactMap { d -> (URL, [Int])? in
            let n = d.lastPathComponent   // gradle-8.7-bin
            let parts = n.split(separator: "-")
            guard parts.count >= 2, let v = Version.pure(String(parts[1])) else { return nil }
            return (d, v)
        }
        if let newest = gradle.max(by: { Version.less($0.1, $1.1) }) {
            for (d, v) in gradle where v != newest.1 {
                add(d, .developer, .safe, "Older Gradle version; \(newest.0.lastPathComponent) is the newest you have.")
            }
        }
        for avd in children(homeURL(".android/avd")) where avd.pathExtension == "avd" {
            add(avd, .developer, .review, "Android emulator \(avd.deletingPathExtension().lastPathComponent); remove it only if you no longer use it.", owner: "qemu-system-aarch64")
        }
        for img in children(homeURL("Library/Android/sdk/system-images")) {
            add(img, .developer, .review, "Android system images for \(img.lastPathComponent); downloaded again from Android Studio.")
        }
        for c in children(homeURL(".cache")) where isNonEmpty(c) {
            let name = c.lastPathComponent
            let models = ["huggingface", "torch", "whisper", "lm-studio", "ollama"].contains(name.lowercased())
            add(c, .developer, .review, models ? "Downloaded AI models (\(name)); downloading them again can be slow."
                                               : "Tool cache (\(name)); usually downloaded or rebuilt again.")
        }
        if let cores = cores {
            for c in children(cores) where c.lastPathComponent.hasPrefix("core") && FS.canMove(c) {
                add(c, .developer, .review, "Core dump of a crashed program; useful only for debugging that crash.")
            }
        }
    }

    /// /Library: leftovers of removed apps. Everything here is root-owned, so items are marked admin.
    private func scanSystemLeftovers() {
        guard let root = systemLibrary else { return }
        func movable(_ u: URL) -> Bool { FS.canMove(u) }
        func third(_ name: String) -> Bool { !index.isApple(name) && !isOwn(name) }

        for dir in ["Caches", "Logs"] {
            for u in children(root.appendingPathComponent(dir)) {
                let name = u.lastPathComponent
                // only app-id names ("com.vendor.app") count: macOS uses plain names here
                guard third(name), AppIndex.isBundleID(name), index.owner(of: name) == .none,
                      !Rules.isAppleCacheDenied(name), !installedByApple(u) else { continue }
                add(u, .systemLeftovers, .safe, "System-wide \(dir == "Caches" ? "cache" : "logs") of an app that is no longer installed.",
                    owner: name, admin: !movable(u))
            }
        }
        for u in children(root.appendingPathComponent("Application Support")) {
            let name = u.lastPathComponent
            guard third(name) else { result.protectedCount += 1; continue }
            switch index.owner(of: name) {
            case .strong, .weak: continue
            case .vendor, .none:
                if installedByApple(u) { result.protectedCount += 1; continue }
                add(u, .systemLeftovers, .review,
                    "System-wide data folder; no installed app matches. Check it holds nothing you need (licences, plug-ins).",
                    admin: !movable(u))
            }
        }
        for u in children(root.appendingPathComponent("Preferences")) where u.pathExtension == "plist" {
            let name = u.lastPathComponent
            guard third(name), !installedByApple(u) else { result.protectedCount += 1; continue }
            switch index.owner(of: name) {
            case .strong, .weak: continue
            case .vendor:
                add(u, .systemLeftovers, .review, "System-wide settings; the same vendor still has other apps installed.", admin: !movable(u))
            case .none:
                add(u, .systemLeftovers, AppIndex.isBundleID(name) ? .safe : .review,
                    "System-wide settings of an app that is no longer installed.", admin: !movable(u))
            }
        }
        // launchd jobs whose program is gone, and helpers no job starts any more
        var started = Set<String>()
        for dir in ["LaunchAgents", "LaunchDaemons"] {
            for u in children(root.appendingPathComponent(dir)) where u.pathExtension == "plist" {
                guard let job = NSDictionary(contentsOf: u) as? [String: Any] else { continue }
                let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first ?? ""
                if !program.isEmpty { started.insert(program) }
                guard third(u.lastPathComponent), program.hasPrefix("/"), !installedByApple(u) else { continue }
                if !fm.fileExists(atPath: program) {
                    add(u, .systemLeftovers, .review,
                        "\(dir == "LaunchDaemons" ? "Background service" : "Login item for all users") that starts \(program), which no longer exists.",
                        admin: !movable(u))
                }
            }
        }
        for u in children(root.appendingPathComponent("PrivilegedHelperTools")) {
            let name = u.lastPathComponent
            // in use when any service runs it or a program inside it (helper .app bundles), or its app is installed
            guard third(name), !started.contains(where: { $0 == u.path || $0.hasPrefix(u.path + "/") }) else { continue }
            switch index.owner(of: name) {
            case .strong, .weak: continue
            default: break
            }
            if installedByApple(u) { continue }
            add(u, .systemLeftovers, .review, "Privileged helper that no system service starts any more.", admin: !movable(u))
        }
    }

    // MARK: - Finish

    private func finish(_ progress: (Double) -> Void) {
        var list = order.compactMap { found[$0] }
        // keep only the outermost item when one candidate sits inside another,
        // unless the outer one is left alone: then the movable pieces inside stay listed
        let movable = Set(list.filter { $0.tier != .blocked }.map(\.id))
        list = list.filter { c in
            var p = c.url.deletingLastPathComponent()
            while p.path.count > 1 {
                if movable.contains(p.path) { return false }
                p = p.deletingLastPathComponent()
            }
            return true
        }
        var sizes = [Int64?](repeating: nil, count: list.count)
        let lock = NSLock()
        let urls = list.map(\.url)
        var measured = 0
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let s = FS.size(of: urls[i])
            lock.lock()
            sizes[i] = s
            measured += 1
            let n = measured
            lock.unlock()
            if n % 4 == 0 || n == urls.count { progress(Double(n) / Double(max(1, urls.count))) }
        }
        progress(1)
        var out: [Candidate] = []
        for (i, var c) in list.enumerated() {
            guard let s = sizes[i] else { result.unreadable += 1; continue }
            if s == 0 && c.area == .developer { continue }   // empty tool folders are noise
            c.size = s
            out.append(c)
        }
        result.candidates = out
    }
}
