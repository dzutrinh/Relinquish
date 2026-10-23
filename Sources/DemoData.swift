import Foundation

/// Made-up results for README screenshots (LC_DEMO_DATA=1). No real paths or projects.
enum DemoData {
    static var enabled: Bool { ProcessInfo.processInfo.environment["LC_DEMO_DATA"] != nil }

    private static let mb: Int64 = 1_000_000

    private static func item(_ path: String, _ area: ScanArea, _ tier: Tier, _ reason: String, _ size: Int64,
                             label: String? = nil, app: String? = nil, admin: Bool = false) -> Candidate {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : FS.home.appendingPathComponent(path)
        var c = Candidate(url: url, area: area, tier: tier, reason: reason, admin: admin, label: label, app: app)
        c.size = size
        return c
    }

    static func scan() -> ScanResult {
        var r = ScanResult()
        r.candidates = [
            item("Library/Caches/com.spotify.client", .appCaches, .safe, "Cache; the app rebuilds it when needed.", 812 * mb),
            item("Library/Caches/com.tinyspeck.slackmacgap", .appCaches, .safe, "Cache; the app rebuilds it when needed.", 344 * mb),
            item("Library/Application Support/Code/CachedExtensionVSIXs", .appCaches, .safe,
                 "Cache folder of Code; rebuilt when needed.", 286 * mb, app: "Visual Studio Code"),
            item("Library/Caches/com.example.PhotoTool", .appCaches, .safe, "Cache of an app that is no longer installed.", 96 * mb),
            item("Library/Logs/com.example.SyncHelper", .appLogs, .safe, "Logs of an app that is no longer installed.", 18 * mb),
            item("Library/Application Support/Zoom/updates/6.1.0", .oldVersions, .safe,
                 "Old program version left behind by an updater; 6.3.2 is the current one.", 210 * mb),
            item("Library/Preferences/com.example.PhotoTool.plist", .leftoverSettings, .safe,
                 "Settings of an app that is no longer installed.", 8_192),
            item("Library/Saved Application State/com.example.PhotoTool.savedState", .leftoverWeb, .safe,
                 "Saved window state of an app that is no longer installed.", 120_000),
            item("Library/Application Support/Code/User/workspaceStorage/4f1c9e27b3", .developer, .safe,
                 "Visual Studio Code state for ~/Projects/old-website, a project folder that no longer exists.", 42 * mb,
                 label: "old-website — workspace state", app: "Visual Studio Code"),
            item("Library/Caches/JetBrains/PyCharm2024.1", .developer, .safe,
                 "Caches of an older PyCharm version; PyCharm2025.2 is current.", 1_240 * mb),
            item(".npm/_cacache", .developer, .safe, "npm download cache; filled again on the next install.", 640 * mb),
            item("Library/Developer/Xcode/DerivedData", .developer, .safe, "Xcode build products; rebuilt on the next build.", 2_310 * mb),
            item("Library/Application Support/Old Game Studio", .leftoverData, .review,
                 "No installed app matches this folder. Check it holds nothing you need (saves, documents, licences).", 380 * mb),
            item(".cache/huggingface", .developer, .review, "Downloaded AI models (huggingface); downloading them again can be slow.", 2_100 * mb),
            item("Library/Application Support/JetBrains/PyCharm2024.1", .developer, .review,
                 "Settings and plug-ins of an older PyCharm version; PyCharm2025.2 is current.", 160 * mb),
            item("Library/Logs/DiagnosticReports", .systemLogs, .review, "Crash reports; keep them while you are tracking down a crash.", 6 * mb),
            item("/Library/LaunchDaemons/com.example.vpn.helper.plist", .systemLeftovers, .review,
                 "Background service that starts /Applications/ExampleVPN.app/Contents/MacOS/helper, which no longer exists.",
                 4_096, admin: true),
            item("Library/LaunchAgents/com.example.updater.plist", .launchAgents, .review,
                 "Starts ~/Applications/Example Updater.app/Contents/MacOS/updater, which no longer exists.", 4_096),
            item("Library/Caches/com.google.Chrome", .appCaches, .blocked,
                 "Google Chrome is running. Quit it and scan again to clean this.", 1_420 * mb),
            item("Library/Application Support/Code/Cache", .appCaches, .blocked,
                 "Code is running. Quit it and scan again to clean this.", 90 * mb, app: "Visual Studio Code"),
        ]
        r.protectedCount = 640
        return r
    }

    static let firstRun = Date(timeIntervalSinceNow: -86_400 * 74)

    static func stats() -> RecoveredStats {
        func session(_ days: Double, _ items: Int, freed: Int64, inTrash: Int64 = 0, restored: Int64 = 0, back: Int = 0, admin: Int = 0)
            -> RecoveredStats.Session {
            RecoveredStats.Session(id: "demo-\(days)", date: Date(timeIntervalSinceNow: -86_400 * days), items: items,
                                   freed: freed, inTrash: inTrash, restored: restored, restoredItems: back, admin: admin)
        }
        var s = RecoveredStats()
        s.sessions = [
            session(2, 14, freed: 0, inTrash: 1_310 * mb),
            session(19, 6, freed: 0, restored: 40 * mb, back: 6),
            session(33, 41, freed: 3_870 * mb, admin: 3),
            session(74, 128, freed: 5_240 * mb),
        ]
        let cats: [(ScanArea, Int64, Int64, Int)] = [
            (.developer, 4_020, 640, 22), (.appCaches, 3_150, 410, 71), (.oldVersions, 820, 0, 6),
            (.systemCaches, 610, 120, 38), (.appLogs, 180, 60, 29), (.leftoverData, 160, 0, 4),
            (.leftoverWeb, 90, 40, 13), (.systemLeftovers, 1, 0, 3), (.leftoverSettings, 1, 0, 3),
        ]
        s.categories = cats.map { RecoveredStats.Category(area: $0.0, freed: $0.1 * mb, inTrash: $0.2 * mb, items: $0.3) }
        s.freed = s.categories.reduce(0) { $0 + $1.freed }
        s.inTrash = s.categories.reduce(0) { $0 + $1.inTrash }
        s.restored = 40 * mb
        s.items = s.categories.reduce(0) { $0 + $1.items }
        return s
    }
}
