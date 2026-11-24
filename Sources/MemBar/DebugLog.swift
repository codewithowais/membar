import AppKit

/// Writes focus changes to ~/Library/Logs/MemBar.log so we can see what steals focus
/// (macOS closes a menu bar panel the moment MemBar stops being the active app).
enum DebugLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/MemBar.log")

    static func write(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func install() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            let front = NSWorkspace.shared.frontmostApplication
            write("RESIGN active -> frontmost: \(front?.localizedName ?? "?") (\(front?.bundleIdentifier ?? "?"))")
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            write("BECAME active")
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            write("window will close: \((n.object as? NSWindow)?.className ?? "?")")
        }
        write("MemBar started pid \(ProcessInfo.processInfo.processIdentifier)")
    }
}
