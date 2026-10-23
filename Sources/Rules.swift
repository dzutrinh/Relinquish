import Foundation

/// What the user can choose to scan. Each candidate belongs to exactly one area.
enum ScanArea: String, CaseIterable, Identifiable, Codable {
    case appCaches, systemCaches, appLogs, systemLogs, oldVersions
    case leftoverSettings, leftoverData, leftoverWeb, launchAgents, developer, systemLeftovers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches: return "App caches"
        case .systemCaches: return "System caches"
        case .appLogs: return "App logs"
        case .systemLogs: return "System logs"
        case .oldVersions: return "Old app versions"
        case .leftoverSettings: return "Leftover settings"
        case .leftoverData: return "Leftover app data"
        case .leftoverWeb: return "Leftover web data"
        case .launchAgents: return "Broken login items"
        case .developer: return "Developer tools"
        case .systemLeftovers: return "System-wide leftovers"
        }
    }

    var detail: String {
        switch self {
        case .appCaches: return "~/Library/Caches and cache folders inside app data. Rebuilt when needed."
        case .systemCaches: return "macOS caches in ~/Library/Caches and /Library/Caches that are regenerable and not in use."
        case .appLogs: return "Log folders of apps in ~/Library/Logs."
        case .systemLogs: return "macOS logs and crash reports in ~/Library/Logs and /Library/Logs."
        case .oldVersions: return "Older copies an updater left next to the current version."
        case .leftoverSettings: return "Preference files of apps that are no longer installed."
        case .leftoverData: return "Application Support folders with no matching app. Always review."
        case .leftoverWeb: return "Cookies, web storage and saved window state of removed apps."
        case .launchAgents: return "Login items that start a program that no longer exists."
        case .developer: return "Leftovers of code editors and IDEs (VS Code, Cursor, JetBrains, Xcode, Sublime, Zed…) and build tool caches (npm, Gradle, Maven, Cargo, Go…)."
        case .systemLeftovers: return "Leftovers of removed apps in /Library: caches, logs, data, settings, background services. Moving them asks for your password."
        }
    }

    static let defaults: Set<ScanArea> = [.appCaches, .appLogs, .oldVersions, .leftoverSettings,
                                           .leftoverData, .leftoverWeb, .launchAgents, .developer]
}

enum Tier: Int, CaseIterable, Identifiable {
    case safe, review, blocked
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .safe: return "Safe to clean"
        case .review: return "Review first"
        case .blocked: return "Left alone"
        }
    }

    var note: String {
        switch self {
        case .safe: return "Regenerable or clearly left over."
        case .review: return "Probably left over, but check before selecting."
        case .blocked: return "In use, owned by a running app, or needs administrator rights."
        }
    }
}

struct Candidate: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let area: ScanArea
    var tier: Tier
    var reason: String
    var size: Int64 = 0
    /// Name of the app whose running state decides whether this item may be moved.
    var owner: String?
    /// Root-owned: moving it needs the user's administrator password.
    var admin = false
    /// Friendlier title than the file name (VS Code's hash-named folders), and the app whose icon to show.
    var label: String? = nil
    var app: String? = nil

    var name: String { label ?? url.lastPathComponent }
    var displayPath: String { Fmt.tilde(url.path) }
}

enum Rules {
    /// Apple's own ids plus the open-source parts macOS ships (printing, ssh, mail, time, cron).
    static let applePrefixes = ["com.apple", "group.com.apple", "systemgroup.com.apple", "apple", "org.cups", "org.openssh",
                                "com.openssh", "org.ntp", "org.postfix", "com.vix", "org.isc", "org.net-snmp", "org.openldap",
                                "com.openldap", "org.samba", "org.apache.httpd", "com.openssl"]

    /// macOS items that look like plain names (normalized). Never offered as leftovers.
    static let appleNames: Set<String> = Set([
        "AddressBook", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "FileProvider", "Knowledge",
        "MobileSync", "FaceTime", "DifferentialPrivacy", "Animoji", "SyncServices", "networkserviceproxy",
        "iCloud", "Dock", "App Store", "AppStore", "Mail", "Messages", "Safari", "Photos", "Music", "TV", "Books",
        "Notes", "Reminders", "Calendars", "Contacts", "GeoServices", "PassKit", "Wallet", "Accounts", "Assistant",
        "Siri", "Spotlight", "QuickLook", "FamilyCircle", "loginwindow", "pbs", "ContextStoreAgent",
        "ScopedBookmarkAgent", "TokenBucketRateLimiter", "diagnostics_agent", "SKGActivityJournal",
        "APMAnalyticsSuiteName", "APMExperimentSuiteName", "ByHost", "no_backup", "MobileMeAccounts",
        ".GlobalPreferences", "GlobalPreferences", "CloudKit", "Metadata", "CoreData", "Biome", "Trial",
        "Keychains", "UnifiedAssetFramework", "MediaAnalysis", "LanguageModeling", "KeyboardServices",
        "FrontBoard", "Passes", "Finance", "HomeKit", "Sharing", "IdentityServices", "Suggestions",
        "SafariSafeBrowsing", "org.cups.PrintingPrefs", "PrintingPrefs", "internetAccountsMigrator",
        "icloudmailagent", "familycircled", "sharedfilelistd", "localizationswitcherd", "mbuseragent",
        "CrashReporter", "DiagnosticReports", "Sync", "PhotosUpgrade", "PhotosSearch", "iPhone Updater Logs",
        "Caches", "Containers", "Group Containers", "Mobile Documents", "CloudStorage", "Daemon Containers",
        "Application Scripts", "Autosave Information", "Cookies", "HTTPStorages", "WebKit", "Fonts", "Sounds",
        "Services", "Accessibility", "Developer", "Logs", "Preferences", "Saved Application State",
        "SoftwareUpdate", "MobileSoftwareUpdate", "com.apple", "Apple", "AppleMediaServices", "DuetExpertCenter",
        "CoreFollowUp", "Screen Time", "ScreenTime", "IntelligencePlatform", "AppleIntelligence", "Weather",
        "Stocks", "Maps", "News", "Podcasts", "Freeform", "Journal", "Passwords", "Home", "Shortcuts",
        "Image Capture", "Preview", "TextEdit", "Xcode", "Simulator", "Instruments", "icdd", "Databases", "WebPush",
        "LocalStorage", "IndexedDB", "Script Editor", "iLifeMediaBrowser", "ProApps", "MobileDevice", "DirectoryServices",
        "SystemConfiguration", "Audio", "CoreMediaIO", "Security", "OpenDirectory", "Bluetooth", "ApplePushService",
        "Automator", "Printers", "CoreAnalytics", "Displays", "Sandbox", "Managed Preferences", "Ubiquity", "FileSync",
        "Logging", "Spotlight", "Updates", "Receipts", "KernelExtensions", "Extensions", "Filesystems", "Frameworks",
        "Modem Scripts", "Perl", "Ruby", "Python", "Java", "Image Capture", "Graphics", "Components", "Compositions",
        "Desktop Pictures", "Documentation", "DriverExtensions", "GPUBundles", "Internet Plug-Ins", "Keyboard Layouts",
        "OSAnalytics", "Raft", "ColorSync", "AirPort", "Apple", "com.apple.TCC", "CS", "Mail", "Messages", "AppleUSBDevice", "BTServer", "WindowServer", "Xsan", "MCXTools",
        "LKDC-setup", "hidfw-crashlogs", "DiagnosticMessages", "CoreCapture", "Bluetooth", "DeviceLink", "DiscRecording", "fsck_hfs", "fsck_apfs",
    ].map(Tokens.normalize))

    /// Even inside "System caches": stateful or security-related caches are never offered.
    static let appleCacheDeny = ["bird", "cloud", "akd", "nsurlsession", "containermanager", "keychain", "security",
                                 "homekit", "homed", "familycircle", "findmy", "icloud", "softwareupdate", "passkit",
                                 "wallet", "mobileasset", "trustd", "biome", "tcc", "authkit", "accounts",
                                 "appstore", "storekit", "commerce", "installd", "backup", "timemachine", "tm.",
                                 "photos", "mail", "messages", "imessage", "contacts", "notes", "fileprovider"]

    /// Process paths that count as macOS, not as third-party apps.
    static let systemExecutablePrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/",
                                           "/bin/", "/Library/Apple/", "/private/var/", "/Library/Developer/"]

    /// Cache-like folders inside an app's data folder.
    static let cacheFolderNames: Set<String> = [
        "Cache", "Caches", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GraphiteDawnCache", "ShaderCache", "GrShaderCache", "CachedData", "CachedExtensionVSIXs",
        "CachedProfilesData", "Crashpad", "component_crx_cache", "crx_cache", "Service Worker Cache",
    ]
    static let logFolderNames: Set<String> = ["logs", "Logs", "log"]

    static func isAppleCacheDenied(_ name: String) -> Bool {
        let l = name.lowercased()
        return appleCacheDeny.contains { l.contains($0) }
    }
}
