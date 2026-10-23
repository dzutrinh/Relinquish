import Foundation

/// Builds a fake Library in a temp folder and checks the scanner's tiers and every cleaner safeguard.
/// Uses a fake Trash folder; never touches the real Library or Trash.
enum SelfTest {
    private struct DirTrasher: Trasher {
        let dir: URL
        func trash(_ url: URL) throws -> URL? {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    /// Runs the root script as the current user: same script, no privileges.
    private struct ShellRunner: AdminRunner {
        var calls = 0
        func run(_ script: String, prompt: String) -> (output: String?, error: String?) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (nil, "sh failed") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(decoding: data, as: UTF8.self), nil)
        }
    }

    private struct CancelRunner: AdminRunner {
        func run(_ script: String, prompt: String) -> (output: String?, error: String?) { (nil, "you cancelled the password prompt") }
    }

    static func run() -> Int32 {
        var fails = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok    " : "FAIL  ", what)
            if !ok { fails += 1 }
        }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relinquish-selftest-\(getpid())")
        let lib = base.appendingPathComponent("Library")
        let sysCaches = base.appendingPathComponent("SysCaches")
        let sysLogs = base.appendingPathComponent("SysLogs")
        let trash = base.appendingPathComponent("Trash")
        defer { try? fm.removeItem(at: base) }

        @discardableResult
        func mk(_ rel: String, under root: URL? = nil, data: Data = Data(repeating: 7, count: 4096)) -> URL {
            let u = (root ?? lib).appendingPathComponent(rel)
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: u.path, contents: data)
            return u
        }
        func exists(_ rel: String, under root: URL? = nil) -> Bool {
            (try? fm.attributesOfItem(atPath: (root ?? lib).appendingPathComponent(rel).path)) != nil
        }

        // --- pure helpers
        check(Version.pure("2.1.295") == [2, 1, 295], "version: plain")
        check(Version.pure("46.3.1.34493_390bb864-0b34") == [46, 3, 1, 34493], "version: with build tag")
        check(Version.pure("Cache") == nil && Version.pure("2024") == nil && Version.pure("1.2 copy") == nil, "version: rejects non-versions")
        check(Version.splitSuffix("copilot-desktop-gh-2.96.0")?.base == "copilot-desktop-gh", "version: name-version split")
        check(Version.splitSuffix("github-copilot-git-2.53.0-4")?.base == "github-copilot-git", "version: split with build suffix")
        check(Version.less([2, 96, 0], [2, 101, 0]), "version: numeric compare")
        let empty = AppIndex()
        check(empty.isApple("com.apple.Safari.plist") && empty.isApple("familycircled") && empty.isApple("MobileSync"),
              "apple: prefixes, daemons and known names")
        check(!empty.isApple("Garmin") && !empty.isApple("com.mojang.minecraftlauncher.plist"), "apple: third-party names")

        // --- fixtures
        mk("Caches/com.gone.app/blob")
        mk("Caches/com.running.app/blob")
        mk("Caches/com.later.app/blob")
        mk("Caches/com.apple.harmless/blob")
        mk("Caches/com.apple.bird/blob")
        mk("Caches/tool-1.2.0/x"); mk("Caches/tool-1.10.0/x")
        mk("Application Support/Gone Vendor/save.dat")
        mk("Application Support/Installed App/Cache/c")
        let macho = Data([0xcf, 0xfa, 0xed, 0xfe]) + Data(repeating: 0, count: 64)
        for v in ["1.0.0", "2.0.0"] {
            let p = mk("Application Support/Installed App/versions/\(v)/bin/prog", data: macho)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
        mk("Application Support/Installed App/configs/4.1/prefs.txt")
        mk("Application Support/Installed App/configs/4.2/prefs.txt")
        let busy = mk("Application Support/Busy App/Cache/open.db")
        mk("Preferences/com.gone.app.plist")
        mk("Preferences/com.installed.app.plist")
        mk("Preferences/com.installedvendor.other.plist")
        mk("Preferences/loginwindow.plist")
        mk("Preferences/Zebrafish.plist")
        mk("Preferences/ByHost/com.gone.app.0A1B2C3D-0000-1111-2222-333344445555.plist")
        mk("Saved Application State/com.gone.app.savedState/data.data")
        mk("Logs/GoneLogs/a.log")
        mk("Logs/DiagnosticReports/x.ips")
        mk("Keychains/login.keychain-db")
        let agent = lib.appendingPathComponent("LaunchAgents/com.gone.agent.plist")
        try? fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        (["Label": "com.gone.agent", "Program": "/nonexistent/prog"] as NSDictionary).write(to: agent, atomically: true)
        mk("Outside/precious.txt", under: base)
        try? fm.createSymbolicLink(at: lib.appendingPathComponent("Caches/evil"),
                                   withDestinationURL: base.appendingPathComponent("Outside"))
        mk("com.vendor.cache/x", under: sysCaches)
        try? fm.createDirectory(at: sysLogs, withIntermediateDirectories: true)

        let idx = AppIndex()
        idx.addApp(id: "com.installed.app", names: ["Installed App"], system: false)
        idx.addApp(id: "com.installedvendor.main", names: ["Main Thing"], system: false)
        idx.addApp(id: "com.busy.app", names: ["Busy App"], system: false)
        idx.addApp(id: "com.running.app", names: ["Running"], system: false)
        idx.addApp(id: "com.later.app", names: ["Later"], system: false)
        idx.addRunning(id: "com.running.app", names: ["Running"], system: false)
        let open = PathSet([busy.path])

        // fake /Library with leftovers of a removed app
        let sysLib = base.appendingPathComponent("SysLibrary")
        mk("Application Support/GoneSysVendor/plugin.bin", under: sysLib)
        mk("Application Support/Apple/keep.bin", under: sysLib)
        mk("Preferences/com.gone.sysapp.plist", under: sysLib)
        mk("Preferences/com.apple.loginwindow.plist", under: sysLib)
        mk("PrivilegedHelperTools/com.gone.helper", under: sysLib)
        mk("PrivilegedHelperTools/com.started.helper", under: sysLib)
        let daemon = sysLib.appendingPathComponent("LaunchDaemons/com.gone.daemon.plist")
        try? fm.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
        (["Label": "com.gone.daemon", "Program": "/nonexistent/daemon"] as NSDictionary).write(to: daemon, atomically: true)
        (["Label": "com.started", "Program": sysLib.appendingPathComponent("PrivilegedHelperTools/com.started.helper").path] as NSDictionary)
            .write(to: sysLib.appendingPathComponent("LaunchDaemons/com.started.plist"), atomically: true)

        // developer tools: editors, IDE versions, build caches (home = base)
        let vsx = base.appendingPathComponent(".vscode/extensions")
        for n in ["pub.ext-1.0.0", "pub.ext-2.0.0", "pub.old-0.1.0"] { mk("\(n)/package.json", under: vsx) }
        fm.createFile(atPath: vsx.appendingPathComponent("extensions.json").path,
                      contents: Data(#"[{"relativeLocation":"pub.ext-2.0.0"}]"#.utf8))
        fm.createFile(atPath: vsx.appendingPathComponent(".obsolete").path, contents: Data(#"{"pub.old-0.1.0":true}"#.utf8))
        mk("x-1.0.0/package.json", under: base.appendingPathComponent(".cursor/extensions"))
        let ws = lib.appendingPathComponent("Application Support/Code/User/workspaceStorage")
        mk("Live/main.c", under: base)
        mk("aaa/state.vscdb", under: ws); mk("bbb/state.vscdb", under: ws); mk("ccc/state.vscdb", under: ws)
        fm.createFile(atPath: ws.appendingPathComponent("ccc/workspace.json").path,
                      contents: Data("{\"folder\":\"\(base.appendingPathComponent("Live/gone-subproject").absoluteString)\"}".utf8))
        fm.createFile(atPath: ws.appendingPathComponent("aaa/workspace.json").path, contents: Data(#"{"folder":"file:///nonexistent/gone-project"}"#.utf8))
        fm.createFile(atPath: ws.appendingPathComponent("bbb/workspace.json").path,
                      contents: Data("{\"folder\":\"\(base.appendingPathComponent("Live").absoluteString)\"}".utf8))
        mk("Application Support/Code/CachedData/oldbuild/x")
        mk("Application Support/Code/CachedData/newbuild/x")
        try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 30)],
                              ofItemAtPath: lib.appendingPathComponent("Application Support/Code/CachedData/oldbuild").path)
        for v in ["2023.1", "2024.2"] {
            mk("Caches/JetBrains/PyCharm\(v)/index.bin")
            mk("Application Support/JetBrains/PyCharm\(v)/options.xml")
        }
        mk("Logs/JetBrains/PyCharm2023.1/idea.log")
        mk(".npm/_cacache/blob", under: base)
        mk(".gradle/wrapper/dists/gradle-7.6-bin/x", under: base)
        mk(".gradle/wrapper/dists/gradle-8.7-bin/x", under: base)
        mk(".cache/huggingface/model.bin", under: base)
        mk(".ssh/id_ed25519", under: base)
        let coresDir = base.appendingPathComponent("cores")
        mk("core.4242", under: coresDir)
        idx.addApp(id: "com.microsoft.VSCode", names: ["Visual Studio Code", "Code"], system: false)
        idx.addApp(id: "com.jetbrains.pycharm", names: ["PyCharm"], system: false)

        var steps: [Double] = []
        let r = Scanner(index: idx, open: open, areas: Set(ScanArea.allCases), library: lib,
                        systemCaches: sysCaches, systemLogs: sysLogs, systemLibrary: sysLib, cores: coresDir).scan { _, f in steps.append(f) }
        check(!steps.isEmpty && steps.last == 1 && zip(steps, steps.dropFirst()).allSatisfy { $0.0 <= $0.1 + 0.0001 },
              "progress rises to 100% (\(steps.count) updates)")
        func cand(_ rel: String, under root: URL? = nil) -> Candidate? {
            let p = (root ?? lib).appendingPathComponent(rel).path
            return r.candidates.first { $0.url.path == p }
        }
        func tier(_ rel: String, under root: URL? = nil) -> Tier? { cand(rel, under: root)?.tier }

        // --- scanner tiers
        check(tier("Caches/com.gone.app") == .safe, "cache of a removed app is safe")
        check(tier("Caches/com.running.app") == .blocked, "cache of a running app is left alone")
        check(tier("Caches/com.apple.harmless") == .safe, "regenerable macOS cache is offered")
        check(tier("Caches/com.apple.bird") == nil, "iCloud/sync macOS cache is never offered")
        check(cand("Caches/tool-1.2.0")?.reason.hasPrefix("Older cached version") == true, "older cached version detected")
        check(tier("Application Support/Gone Vendor") == .review, "orphan app data needs review")
        check(tier("Application Support/Installed App") == nil, "installed app data is not offered")
        check(tier("Application Support/Installed App/Cache") == .safe, "cache folder inside app data is safe")
        check(tier("Application Support/Installed App/versions/1.0.0") == .safe, "old program version is safe")
        check(tier("Application Support/Installed App/versions/2.0.0") == nil, "newest program version is kept")
        check(tier("Application Support/Installed App/configs/4.1") == .review, "old settings version needs review")
        check(tier("Application Support/Busy App/Cache") == .blocked, "folder with an open file is left alone")
        check(tier("Preferences/com.gone.app.plist") == .safe, "settings of a removed app are safe")
        check(tier("Preferences/com.installed.app.plist") == nil, "settings of an installed app are not offered")
        check(tier("Preferences/com.installedvendor.other.plist") == .review, "same-vendor settings need review")
        check(tier("Preferences/loginwindow.plist") == nil, "macOS settings are never offered")
        check(tier("Preferences/Zebrafish.plist") == .review, "plain-name settings need review")
        check(tier("Preferences/ByHost/com.gone.app.0A1B2C3D-0000-1111-2222-333344445555.plist") == .safe, "ByHost leftover found")
        check(tier("Saved Application State/com.gone.app.savedState") == .safe, "leftover window state is safe")
        check(tier("Logs/GoneLogs") == .safe, "app logs are safe")
        check(tier("Logs/DiagnosticReports") == .review, "crash reports need review")
        check(tier("LaunchAgents/com.gone.agent.plist") == .review, "broken login item found")
        check(!r.candidates.contains { $0.url.path.contains("/Keychains/") }, "keychains are never scanned")
        check(tier("Caches/evil") == .safe && cand("Caches/evil")?.size == 0, "symlink is measured as a link, not followed")
        check(tier("com.vendor.cache", under: sysCaches) == .safe, "movable system-wide cache offered")
        check(tier("Application Support/GoneSysVendor", under: sysLib) == .review, "system-wide orphan data needs review")
        check(tier("Application Support/Apple", under: sysLib) == nil, "macOS system data never offered")
        check(tier("Preferences/com.gone.sysapp.plist", under: sysLib) == .safe, "system-wide orphan settings found")
        check(tier("Preferences/com.apple.loginwindow.plist", under: sysLib) == nil, "macOS system settings never offered")
        check(tier("LaunchDaemons/com.gone.daemon.plist", under: sysLib) == .review, "broken background service found")
        check(tier("PrivilegedHelperTools/com.gone.helper", under: sysLib) == .review, "unused privileged helper found")
        check(tier("PrivilegedHelperTools/com.started.helper", under: sysLib) == nil, "helper still started by a service is kept")
        check(tier("pub.ext-1.0.0", under: vsx) == .safe && tier("pub.old-0.1.0", under: vsx) == .safe, "dev: unused extension versions found")
        check(tier("pub.ext-2.0.0", under: vsx) == nil, "dev: the extension version in use is kept")
        check(tier(".cursor/extensions", under: base) == .review, "dev: extensions of an uninstalled editor need review")
        check(tier("ccc", under: ws) == .safe && tier("bbb", under: ws) == nil, "dev: state of a deleted project is safe, live one kept")
        check(tier("aaa", under: ws) == .review, "dev: project whose parent is gone too needs review (offline drive?)")
        check(tier("Application Support/Code/CachedData") == .safe || tier("Application Support/Code/CachedData/oldbuild") == .safe,
              "dev: old compiled-code cache offered")
        check(tier("Application Support/Code/CachedData/newbuild") == nil, "dev: current build cache not offered alone")
        check(tier("Caches/JetBrains/PyCharm2023.1") == .safe, "dev: old IDE caches safe (\(String(describing: cand("Caches/JetBrains/PyCharm2023.1")?.reason)))")
        check(tier("Logs/JetBrains/PyCharm2023.1") == .safe, "dev: old IDE logs safe (\(String(describing: cand("Logs/JetBrains/PyCharm2023.1")?.reason)))")
        check(tier("Application Support/JetBrains/PyCharm2023.1") == .review, "dev: old IDE settings need review")
        check(tier("Application Support/JetBrains/PyCharm2024.2") == nil, "dev: current IDE settings kept")
        check(tier("Caches/JetBrains/PyCharm2024.2") == .review, "dev: current IDE caches need review (re-indexing)")
        check(tier(".npm/_cacache", under: base) == .safe, "dev: npm cache found")
        check(tier(".gradle/wrapper/dists/gradle-7.6-bin", under: base) == .safe && tier(".gradle/wrapper/dists/gradle-8.7-bin", under: base) == nil,
              "dev: only older Gradle versions offered")
        check(tier(".cache/huggingface", under: base) == .review, "dev: model caches need review")
        check(tier("core.4242", under: coresDir) == .review, "dev: core dumps found")
        check(!r.candidates.contains { $0.url.path.contains("/.ssh") }, "dev: ssh keys never scanned")

        // --- cleaner safeguards
        let adminRoots = ["Caches", "Logs", "Application Support", "Preferences", "LaunchAgents", "LaunchDaemons",
                          "PrivilegedHelperTools"].map { sysLib.appendingPathComponent($0) }
        let cleaner = Cleaner(library: lib, systemRoots: [sysCaches, sysLogs, coresDir], trasher: DirTrasher(dir: trash),
                              historyDir: base.appendingPathComponent("History"), adminRoots: adminRoots,
                              adminRunner: ShellRunner(), trashDir: trash)
        let forged = [
            Candidate(url: base.appendingPathComponent("Outside/precious.txt"), area: .appCaches, tier: .safe, reason: ""),
            Candidate(url: lib.appendingPathComponent("Keychains/login.keychain-db"), area: .appCaches, tier: .safe, reason: ""),
            Candidate(url: lib.appendingPathComponent("Preferences/loginwindow.plist"), area: .leftoverSettings, tier: .safe, reason: ""),
            Candidate(url: lib.appendingPathComponent("Caches"), area: .appCaches, tier: .safe, reason: ""),
            Candidate(url: lib.appendingPathComponent("Caches/../Keychains"), area: .appCaches, tier: .safe, reason: ""),
            Candidate(url: lib.appendingPathComponent("Caches/evil/precious.txt"), area: .appCaches, tier: .safe, reason: ""),
            Candidate(url: base.appendingPathComponent(".ssh/id_ed25519"), area: .developer, tier: .safe, reason: ""),
            Candidate(url: base.appendingPathComponent(".npm"), area: .developer, tier: .safe, reason: ""),
            Candidate(url: vsx.appendingPathComponent("pub.ext-2.0.0"), area: .appCaches, tier: .safe, reason: ""),
        ]
        idx.addRunning(id: "com.later.app", names: ["Later"], system: false)   // started after the scan
        // treat the fake system leftovers as root-owned so they take the administrator path
        let asAdmin = r.candidates.map { c -> Candidate in
            var c = c
            if c.url.path.hasPrefix(sysLib.path + "/") { c.admin = true }
            return c
        }
        let forgedAdmin = [
            Candidate(url: sysLib.appendingPathComponent("Application Support/Apple"), area: .systemLeftovers, tier: .safe, reason: "", admin: true),
            Candidate(url: base.appendingPathComponent("Outside/precious.txt"), area: .systemLeftovers, tier: .safe, reason: "", admin: true),
        ]
        let rep = cleaner.clean(asAdmin + forged + forgedAdmin, index: idx, open: open)
        check(!exists("Application Support/GoneSysVendor", under: sysLib) && !exists("Preferences/com.gone.sysapp.plist", under: sysLib),
              "administrator path moves system-wide leftovers")
        check(exists("Application Support/Apple/keep.bin", under: sysLib), "administrator path refuses macOS system data")
        check(exists("Outside/precious.txt", under: base), "administrator path refuses paths outside /Library")
        check(exists("PrivilegedHelperTools/com.started.helper", under: sysLib), "administrator path leaves unlisted items")
        check(exists("Outside/precious.txt", under: base), "refuses a path outside the Library")
        check(exists("Keychains/login.keychain-db"), "refuses folders outside the cleanable areas")
        check(exists("Preferences/loginwindow.plist"), "refuses macOS settings even if asked")
        check(exists("Caches"), "refuses a whole area folder")
        check(exists("Caches/com.running.app"), "never moves a blocked item")
        check(exists("Application Support/Busy App/Cache/open.db"), "never moves an item with open files")
        check(exists("Caches/com.later.app"), "re-checks running apps at clean time")
        check(rep.skipped.contains { $0.why.contains("running now") }, "reports the app that started since the scan")
        check(!exists("Caches/com.gone.app"), "moves a safe item")
        check(!exists("Caches/evil") && exists("Outside/precious.txt", under: base), "moves the link itself, not its target")
        check(!exists("Application Support/Installed App/versions/1.0.0") && exists("Application Support/Installed App/versions/2.0.0"),
              "moves only the old version")
        check(cleaner.canRestore, "keeps a restore log")
        check(!exists(".npm/_cacache", under: base) && !exists("pub.ext-1.0.0", under: vsx) && !exists("ccc", under: ws),
              "dev: developer leftovers move")
        check(exists(".ssh/id_ed25519", under: base), "dev: refuses folders outside the developer allowlist")
        check(exists(".npm", under: base), "dev: refuses a whole tool folder")
        check(exists("pub.ext-2.0.0", under: vsx), "dev: refuses developer folders for other areas")
        check(!exists("core.4242", under: coresDir), "dev: core dump moves")

        // --- space recovered: right after the clean everything waits in the (fake) Trash
        let hist = base.appendingPathComponent("History")
        let st1 = RecoveredStats.load(from: hist)
        check(st1.inTrash == rep.bytes && st1.freed == 0 && st1.items == rep.done.count, "recovered: cleaned space counts as in the Trash")
        check(st1.categories.contains { $0.area == .appCaches } && st1.categories.contains { $0.area == .systemLeftovers },
              "recovered: grouped by category")
        check(st1.categories.reduce(Int64(0)) { $0 + $1.total } == st1.total, "recovered: categories add up to the total")

        // --- restore
        let res = cleaner.restoreLast()
        check(res.done.count == rep.done.count && res.skipped.isEmpty, "restores every moved item (\(res.done.count))")
        check(exists("Caches/com.gone.app") && exists("Application Support/Installed App/versions/1.0.0"), "items are back in place")
        check(!cleaner.canRestore, "a restored log is not reused")
        let st2 = RecoveredStats.load(from: hist)
        check(st2.total == 0 && st2.restored == rep.bytes && st2.sessions.first?.state == .restored,
              "recovered: restored items are not counted")

        // --- logs written before categories were kept, then emptied
        let legacy = HistorySession(date: Date(timeIntervalSince1970: 1_800_000_000), items: [
            HistoryItem(original: FS.library.path + "/Caches/com.gone.legacy", trashed: "/nonexistent/a", size: 1000),
            HistoryItem(original: FS.library.path + "/Caches/com.apple.legacy", trashed: "/nonexistent/b", size: 300),
            HistoryItem(original: FS.library.path + "/Application Support/Some App/Cache", trashed: "/nonexistent/c", size: 50),
            HistoryItem(original: FS.library.path + "/Application Support/Some App/versions/1.0.0", trashed: "/nonexistent/d", size: 20),
            HistoryItem(original: FS.library.path + "/Preferences/com.gone.legacy.plist", trashed: "/nonexistent/e", size: 4),
            HistoryItem(original: "/Library/LaunchDaemons/com.gone.legacy.plist", trashed: "/nonexistent/f", size: 4, admin: true),
        ])
        if let data = try? Cleaner.encoder.encode(legacy) {
            try? data.write(to: hist.appendingPathComponent("2027-01-15T08-00-00.emptied.json"))
        }
        let st3 = RecoveredStats.load(from: hist)
        func cat(_ a: ScanArea) -> Int64 { st3.categories.first { $0.area == a }?.freed ?? -1 }
        check(st3.freed == 1378 && st3.inTrash == 0, "recovered: an emptied cleanup counts as freed")
        check(cat(.appCaches) == 1050 && cat(.systemCaches) == 300 && cat(.oldVersions) == 20
              && cat(.leftoverSettings) == 4 && cat(.systemLeftovers) == 4, "recovered: categories inferred for old logs")
        check(st3.sessions.first?.state == .freed && st3.sessions.first?.admin == 1, "recovered: newest cleanup first, system-wide counted")

        check(exists("Application Support/GoneSysVendor", under: sysLib) && exists("Preferences/com.gone.sysapp.plist", under: sysLib),
              "administrator items are put back too")

        // --- root script quoting: hostile names survive the shell
        let weird = ["it's a \"test\" $HOME `id`", "semi;colon & pipe|", "back\\slash *glob?", "  spaces  "]
        let qdir = base.appendingPathComponent("Quote")
        var pairs: [(from: String, to: String)] = []
        for (i, n) in weird.enumerated() {
            let src = mk(n, under: qdir)
            pairs.append((from: src.path, to: qdir.appendingPathComponent("moved-\(i)/" + n).path))
        }
        mk("taken", under: qdir); mk("moved-x/taken", under: qdir)
        pairs.append((from: qdir.appendingPathComponent("taken").path, to: qdir.appendingPathComponent("moved-x/taken").path))
        pairs.append((from: qdir.appendingPathComponent("missing").path, to: qdir.appendingPathComponent("moved-y/missing").path))
        let out = ShellRunner().run(AdminScript.move(pairs), prompt: "")
        let st = AdminScript.parse(out.output ?? "")
        check(weird.indices.allSatisfy { st[pairs[$0].from] == "ok" && fm.fileExists(atPath: pairs[$0].to) }, "hostile file names move intact")
        check(st[pairs[weird.count].from] == "exists" && exists("taken", under: qdir), "never overwrites an existing destination")
        check(st[pairs[weird.count + 1].from] == "gone", "reports items that vanished")
        check(!fm.fileExists(atPath: NSHomeDirectory() + "/id") , "no command injection")

        // --- cancelled password prompt moves nothing
        let victim = mk("Preferences/com.gone.cancel.plist", under: sysLib)
        let cancelCleaner = Cleaner(library: lib, systemRoots: [], trasher: DirTrasher(dir: trash),
                                    historyDir: base.appendingPathComponent("History2"), adminRoots: adminRoots,
                                    adminRunner: CancelRunner(), trashDir: trash)
        let cr = cancelCleaner.clean([Candidate(url: victim, area: .systemLeftovers, tier: .safe, reason: "", admin: true)], index: idx, open: open)
        check(fm.fileExists(atPath: victim.path) && cr.skipped.first?.why.contains("cancelled") == true, "cancelled prompt moves nothing")

        // --- migration from the old name
        do {
            let nd = MemoryPrefs(), od = MemoryPrefs(["scanAreas": ["appCaches", "developer"]])
            let oldHist = base.appendingPathComponent("Old/LibraryCleaner/History")
            let newHist = base.appendingPathComponent("New/Relinquish/History")
            mk("2026-01-01T00-00-00.json", under: oldHist, data: Data("{}".utf8))
            mk("clash.json", under: oldHist, data: Data("old".utf8))
            mk("clash.json", under: newHist, data: Data("new".utf8))
            Migration.run(defaults: nd, old: od, oldHistory: oldHist, newHistory: newHist)
            check(nd.object(forKey: "scanAreas") as? [String] == ["appCaches", "developer"], "migration: saved areas carried over")
            check(fm.fileExists(atPath: newHist.appendingPathComponent("2026-01-01T00-00-00.json").path), "migration: cleanup logs moved")
            check((try? String(contentsOf: newHist.appendingPathComponent("clash.json"))) == "new"
                  && fm.fileExists(atPath: oldHist.appendingPathComponent("clash.json").path), "migration: never overwrites, keeps the old file")
            nd.set(["oldVersions"], forKey: "scanAreas")
            Migration.run(defaults: nd, old: od, oldHistory: oldHist, newHistory: newHist)
            check(nd.object(forKey: "scanAreas") as? [String] == ["oldVersions"], "migration: runs only once")
        }

        // --- empty trash (fake folder, direct mode)
        mk("leftover.bin", under: trash)
        let bin = TrashBin(dir: trash, useFinder: false)
        check(bin.itemCount() ?? 0 > 0, "fake Trash has items")
        check(bin.empty() == nil && bin.itemCount() == 0, "empties the Trash")

        print(fails == 0 ? "\nall checks passed" : "\n\(fails) checks FAILED")
        return fails == 0 ? 0 : 1
    }
}
