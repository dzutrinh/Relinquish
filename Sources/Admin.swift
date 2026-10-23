import Foundation

/// Runs a shell script as root. The real runner shows macOS's own password dialog;
/// the password never passes through this app.
protocol AdminRunner {
    /// Returns the script's output, or an error message (nil output) when it did not run.
    func run(_ script: String, prompt: String) -> (output: String?, error: String?)
}

struct SystemAdminRunner: AdminRunner {
    func run(_ script: String, prompt: String) -> (output: String?, error: String?) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"\(esc(script))\" with prompt \"\(esc(prompt))\" with administrator privileges without altering line endings"
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err {
            if let n = err[NSAppleScript.errorNumber] as? Int, n == -128 { return (nil, "you cancelled the password prompt") }
            return (nil, (err[NSAppleScript.errorMessage] as? String) ?? "the administrator step failed")
        }
        return (result?.stringValue ?? "", nil)
    }
}

/// Builds the root script that moves items one by one, re-checking each just before the move.
enum AdminScript {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// Output: one "<status>\t<source>" line per pair; status is ok, gone, exists, busy or fail.
    static func move(_ pairs: [(from: String, to: String)]) -> String {
        var lines = ["export PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        for (src, dst) in pairs {
            lines.append("p=\(quote(src)); d=\(quote(dst))")
            lines.append(#"""
            if [ ! -e "$p" ] && [ ! -L "$p" ]; then printf 'gone\t%s\n' "$p"
            elif [ -e "$d" ] || [ -L "$d" ]; then printf 'exists\t%s\n' "$p"
            elif { [ -d "$p" ] && [ ! -L "$p" ] && lsof -t +D "$p" >/dev/null 2>&1; } || lsof -t "$p" >/dev/null 2>&1; then printf 'busy\t%s\n' "$p"
            elif mkdir -p "$(dirname "$d")" && mv -n "$p" "$d" && [ ! -e "$p" ] && [ ! -L "$p" ]; then printf 'ok\t%s\n' "$p"
            else printf 'fail\t%s\n' "$p"; fi
            """#)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(_ output: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[1]] = parts[0] }
        }
        return out
    }

    static func explain(_ status: String?) -> String {
        switch status {
        case "gone": return "it is already gone"
        case "exists": return "something with that name is already in the Trash"
        case "busy": return "a running program has files open inside it"
        case nil: return "the administrator step did not report on it"
        default: return "it could not be moved"
        }
    }
}
