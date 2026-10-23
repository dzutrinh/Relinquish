import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--report") { CLI.report(all: args.contains("--all")); exit(0) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { CLI.snapshot(args[i + 1]); exit(0) }
        if let i = args.firstIndex(of: "--why"), i + 1 < args.count { CLI.why(args[i + 1]); exit(0) }
        RelinquishApp.main()
    }
}

struct RelinquishApp: App {
    private let model = AppModel()

    var body: some Scene {
        WindowGroup("Relinquish") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { Demo.start(model) }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

/// Headless modes: a dry-run report of the real Library and a PNG of the window. Both are read-only.
enum CLI {
    static func scanNow(all: Bool) -> ScanResult {
        let areas = all ? Set(ScanArea.allCases) : ScanArea.defaults
        fputs("indexing apps…\n", stderr)
        let index = AppIndex.live()
        fputs("checking open files…\n", stderr)
        let open = PathSet.openFiles(under: FS.openFileRoots)
        return Scanner(index: index, open: open, areas: areas).scan { s, _ in fputs("scanning: \(s)\n", stderr) }
    }

    static func report(all: Bool) {
        let r = scanNow(all: all)
        for tier in Tier.allCases {
            let rows = r.candidates.filter { $0.tier == tier }.sorted { $0.size > $1.size }
            guard !rows.isEmpty else { continue }
            let total = rows.reduce(Int64(0)) { $0 + $1.size }
            print("\n== \(tier.title): \(rows.count) items, \(Fmt.bytes(total))")
            for c in rows {
                let size = Fmt.bytes(c.size).padding(toLength: 10, withPad: " ", startingAt: 0)
                print("  \(size) [\(c.area.title)] \(c.displayPath)")
                print("             \(c.reason)")
            }
        }
        print("\nprotected macOS items: \(r.protectedCount), need admin: \(r.needsAdmin), unreadable: \(r.unreadable)")
        print("nothing was changed")
    }

    /// Explains how the index sees one name or path: ownership, running state, open files.
    static func why(_ arg: String) {
        let index = AppIndex.live()
        let name = (arg as NSString).lastPathComponent
        print("name: \(name)")
        print("apple: \(index.isApple(name))  owner: \(index.owner(of: name))  running: \(index.isRunning(name))")
        print("tokens: \(Tokens.of(AppIndex.stripExt(name)).sorted())")
        print("running tokens hit: \(Tokens.of(AppIndex.stripExt(name)).intersection(index.runTokens).sorted())")
        if arg.hasPrefix("/") {
            let open = PathSet.openFiles(under: FS.openFileRoots)
            print("open files known: \(open.paths.count)  inside: \(open.anyInside(arg))  process inside: \(index.processes.anyInside(arg))")
        }
    }

    static func snapshot(_ path: String) {
        _ = NSApplication.shared
        let model = AppModel()
        model.apply(scanNow(all: true))
        let view = NSHostingView(rootView: ContentView(model: model).frame(width: 1100, height: 720))
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// Screenshot modes, never used in normal runs: LC_DEMO=welcome|scan|selected|confirm|admin|dev|recovered|banner
/// opens the window in that state ("banner" shows a made-up cleanup report; nothing is moved).
/// LC_SHOT=<png> photographs the window after LC_SHOT_DELAY seconds (default 9) and quits.
enum Demo {
    static func start(_ model: AppModel) {
        guard let mode = ProcessInfo.processInfo.environment["LC_DEMO"] else { return }
        if let shot = ProcessInfo.processInfo.environment["LC_SHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["LC_SHOT_DELAY"] ?? "") ?? 9
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { capture(shot, model); exit(0) }
        }
        if ProcessInfo.processInfo.environment["LC_SHOT"] != nil {
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: 1120, height: 720))
            }
        }
        if mode == "welcome" { return }
        if mode == "recovered" { model.showRecovered = true; return }
        if mode == "scan" { model.areas = Set(ScanArea.allCases); model.scan(); return }
        DispatchQueue.global().async {
            let r = DemoData.enabled ? DemoData.scan() : CLI.scanNow(all: true)
            DispatchQueue.main.async {
                model.apply(r)
                if mode == "dev" {
                    model.focusArea = .developer
                    if DemoData.enabled { for c in model.items(.safe).filter({ $0.area == .developer }).prefix(3) { model.set(c, true) } }
                    for g in Tier.allCases.flatMap({ model.groups($0) }) { model.setExpanded(g.id, true) }
                }
                if mode == "admin" {
                    model.focusArea = .systemLeftovers
                    for c in model.items(.review).filter({ $0.area == .systemLeftovers }).prefix(3) { model.set(c, true) }
                    for g in Tier.allCases.flatMap({ model.groups($0) }) { model.setExpanded(g.id, true) }
                }
                if mode == "confirm" || mode == "selected" {
                    for c in model.items(.safe).prefix(DemoData.enabled ? 5 : 6) { model.set(c, true) }
                    if DemoData.enabled { for g in model.groups(.safe) where model.state(of: g.items) != .off { model.setExpanded(g.id, true) } }
                    if mode == "confirm" { model.confirmClean = true }
                }
                if mode == "banner" {
                    var rep = CleanReport(title: "Cleanup finished")
                    rep.done = [("~/Library/Caches/Zotero", 552_400_000), ("~/Library/Caches/org.yanex.marta", 155_000_000)]
                    model.banner = rep
                    model.canRestore = true
                }
            }
        }
    }
}

extension Demo {
    /// Photographs this app's own main window (no Screen Recording permission needed for own windows).
    /// The translucent sidebar does not capture, so it is rendered on a solid background and drawn in.
    static func capture(_ path: String, _ model: AppModel) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frame = w.contentView?.superview else { return }
        func write(_ rep: NSBitmapImageRep, _ p: String) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
        }
        func snap(_ v: NSView) -> NSBitmapImageRep? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        guard let rep = snap(frame) else { return }
        if let split = findSplit(w.contentView), let pane = split.arrangedSubviews.first {
            let paneRect = pane.convert(pane.bounds, to: frame)
            let contentTop = w.contentLayoutRect.maxY
            let body = NSRect(x: paneRect.minX, y: paneRect.minY, width: paneRect.width,
                              height: min(paneRect.maxY, contentTop) - paneRect.minY)
            let top = NSRect(x: paneRect.minX, y: body.maxY, width: paneRect.width, height: max(0, paneRect.maxY - body.maxY))
            let side = NSHostingView(rootView: Sidebar(model: model)
                .frame(width: body.width, height: body.height)
                .background(Color(nsColor: .underPageBackgroundColor)))
            side.frame = NSRect(origin: .zero, size: body.size)
            side.appearance = w.effectiveAppearance
            let holder = NSWindow(contentRect: side.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            holder.contentView = side
            side.layoutSubtreeIfNeeded()
            if let srep = snap(side), let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                w.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.underPageBackgroundColor.setFill()
                    top.fill()
                    srep.draw(in: body)
                    NSColor.separatorColor.setFill()
                    NSRect(x: body.maxX - 1, y: body.minY, width: 1, height: paneRect.height).fill()
                    // window buttons as the standard traffic lights (their cached images come out square)
                    let lights: [(NSWindow.ButtonType, NSColor)] = [
                        (.closeButton, NSColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1)),
                        (.miniaturizeButton, NSColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1)),
                        (.zoomButton, NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)),
                    ]
                    for (kind, color) in lights {
                        guard let b = w.standardWindowButton(kind) else { continue }
                        let r = b.convert(b.bounds, to: frame)
                        let d: CGFloat = 12
                        color.setFill()
                        NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        write(rep, path)
        if let sheet = w.attachedSheet?.contentView?.superview, let srep = snap(sheet) {
            write(srep, path.replacingOccurrences(of: ".png", with: "_sheet.png"))
        }
    }

    private static func findSplit(_ v: NSView?) -> NSSplitView? {
        guard let v = v else { return nil }
        if let s = v as? NSSplitView { return s }
        for sub in v.subviews { if let s = findSplit(sub) { return s } }
        return nil
    }
}
