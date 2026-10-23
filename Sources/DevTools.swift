import Foundation

/// What the Developer tools area knows about editors, IDEs and build tools.
enum DevTools {
    /// VS Code and its forks share one layout: data in Application Support/<support>, extensions in ~/<extDir>/extensions.
    struct Editor {
        let name: String
        let support: String
        let extDir: String
        let process: String
    }

    static let editors: [Editor] = [
        Editor(name: "Visual Studio Code", support: "Code", extDir: ".vscode", process: "Code"),
        Editor(name: "VS Code Insiders", support: "Code - Insiders", extDir: ".vscode-insiders", process: "Code - Insiders"),
        Editor(name: "VSCodium", support: "VSCodium", extDir: ".vscode-oss", process: "VSCodium"),
        Editor(name: "Cursor", support: "Cursor", extDir: ".cursor", process: "Cursor"),
        Editor(name: "Windsurf", support: "Windsurf", extDir: ".windsurf", process: "Windsurf"),
        Editor(name: "Antigravity", support: "Antigravity", extDir: ".antigravity", process: "Antigravity"),
        Editor(name: "Trae", support: "Trae", extDir: ".trae", process: "Trae"),
        Editor(name: "Kiro", support: "Kiro", extDir: ".kiro", process: "Kiro"),
        Editor(name: "Void", support: "Void", extDir: ".void-editor", process: "Void"),
        Editor(name: "Positron", support: "Positron", extDir: ".positron", process: "Positron"),
    ]

    /// JetBrains product folder prefixes and their app process names.
    static let jetBrainsProcess: [String: String] = [
        "IntelliJIdea": "idea", "IdeaIC": "idea", "PyCharm": "pycharm", "PyCharmCE": "pycharm", "CLion": "clion",
        "WebStorm": "webstorm", "GoLand": "goland", "Rider": "rider", "RubyMine": "rubymine", "PhpStorm": "phpstorm",
        "DataGrip": "datagrip", "DataSpell": "dataspell", "RustRover": "rustrover", "Aqua": "aqua", "Writerside": "writerside",
        "AndroidStudio": "studio", "Fleet": "fleet",
    ]

    /// "PyCharm2024.2" -> ("PyCharm", [2024, 2]); nil for anything else.
    static func ideVersion(_ name: String) -> (product: String, version: [Int])? {
        guard let i = name.firstIndex(where: { $0.isNumber }), i != name.startIndex else { return nil }
        let product = String(name[..<i])
        guard product.allSatisfy({ $0.isLetter }), let v = Version.pure(String(name[i...])), v.first ?? 0 >= 2000 else { return nil }
        return (product, v)
    }

    /// Download and build caches in the home folder: (path from home, tier, reason).
    static let homeCaches: [(path: String, tier: Tier, reason: String)] = [
        (".npm/_cacache", .safe, "npm download cache; filled again on the next install."),
        (".npm/_logs", .safe, "npm debug logs."),
        (".gradle/caches", .safe, "Gradle build cache; downloaded again on the next build."),
        (".gradle/daemon", .safe, "Logs of old Gradle background builds."),
        (".m2/repository", .review, "Maven downloads; fetched again on the next build, which can be slow."),
        (".cargo/registry/cache", .safe, "Cargo download cache; fetched again when needed."),
        (".cargo/registry/src", .safe, "Unpacked Cargo sources; unpacked again when needed."),
        (".cargo/git/checkouts", .safe, "Cargo git checkouts; checked out again when needed."),
        ("go/pkg/mod/cache/download", .safe, "Go module download cache; fetched again when needed."),
        (".pub-cache/hosted", .review, "Dart and Flutter packages; downloaded again on the next pub get."),
        (".bun/install/cache", .safe, "Bun download cache; filled again on the next install."),
        ("Library/pnpm/store", .review, "pnpm package store; projects link to it, so reinstall them after cleaning."),
        (".cocoapods/repos", .review, "CocoaPods spec repositories; cloned again on the next pod install."),
        (".android/cache", .safe, "Android tools cache; rebuilt when needed."),
    ]

    /// Folders outside ~/Library the cleaner may touch (paths from home), and how deep an item must be.
    static let homeRoots: [(path: String, minDepth: Int)] = {
        var r: [(String, Int)] = [(".npm", 1), (".gradle", 1), (".m2", 1), (".cargo", 1), ("go/pkg/mod", 1), (".pub-cache", 1),
                                  (".bun/install", 1), ("Library/pnpm", 1), (".cocoapods", 1), (".android", 1), (".cache", 1),
                                  ("Library/Android/sdk/system-images", 1)]
        r += editors.map { ($0.extDir, 1) }
        return r
    }()
}
