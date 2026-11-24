import Foundation
import AppKit

struct ChromeTab: Identifiable {
    let id: String
    let windowID: String
    let tabID: String
    let title: String
    let url: String          // real page URL (unwrapped from tab-suspender pages)
    let host: String
    let favicon: NSImage?
    var mem: UInt64? = nil      // memory of the renderer process hosting this tab
    var pid: Int32? = nil
    var shared: Int = 1         // how many tabs share that process
    var measured = false

    init(id: String, windowID: String, tabID: String, title: String, url rawURL: String) {
        self.id = id; self.windowID = windowID; self.tabID = tabID; self.title = title
        var real = rawURL
        var icon: NSImage? = nil
        // Tab-suspender extensions park tabs on chrome-extension://…/park.html?url=<real url>&icon=<data uri>
        if rawURL.hasPrefix("chrome-extension://"), let c = URLComponents(string: rawURL) {
            if let u = c.queryItems?.first(where: { $0.name == "url" })?.value { real = u }
            if let i = c.queryItems?.first(where: { $0.name == "icon" })?.value,
               let r = i.range(of: "base64,"),
               let d = Data(base64Encoded: String(i[r.upperBound...])) { icon = NSImage(data: d) }
        }
        self.url = real
        self.host = URL(string: real)?.host ?? real
        self.favicon = icon
    }
}

/// Opens Chrome's own Task Manager, reads which process each tab runs in, closes it,
/// then looks up each process's memory with ps. Needs Accessibility + Automation permission.
func measureChromeTabs(_ input: [ChromeTab]) -> (tabs: [ChromeTab], error: String?) {
    guard chromeRunning() else { return (input, "Chrome is not running.") }
    let script = """
    tell application "Google Chrome" to activate
    delay 0.6
    tell application "System Events"
        tell process "Google Chrome"
            click menu item "Task Manager" of menu "Window" of menu bar 1
            delay 1.5
            set out to ""
            set tbl to missing value
            try
                set w to first window whose name contains "ask manager"
                set tbl to table 1 of group 1 of scroll area 1 of group 1 of group 1 of group 1 of group 1 of group "Task manager" of w
            end try
            if tbl is missing value then
                try
                    set w to first window whose name contains "ask manager"
                    set tbl to first table of (entire contents of w)
                end try
            end if
            if tbl is not missing value then
                repeat with r in rows of tbl
                    try
                        set out to out & (name of r) & linefeed
                    end try
                end repeat
            end if
            keystroke "w" using command down
            return out
        end tell
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return (input, "Could not run osascript.") }
    let data = o.fileHandleForReading.readDataToEndOfFile()
    let errData = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8) ?? ""
        if msg.contains("-1743") || msg.contains("1002") || msg.contains("assistive") || msg.contains("-25211") {
            return (input, "Allow MemBar in System Settings → Privacy & Security → Accessibility and Automation (System Events), then try again.")
        }
        return (input, msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    // Row names look like: "Tab: <title>, <mem>, <cpu>, <net> and <pid>"
    var titleToPids: [String: [Int32]] = [:]
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        guard line.hasPrefix("Tab: ") else { continue }
        var body = String(line.dropFirst(5))
        // Grouped rows append ". Other N tasks in the same task group: ..." after the pid.
        if let r = body.range(of: ". Other ", options: .backwards) { body = String(body[..<r.lowerBound]) }
        guard let andRange = body.range(of: " and ", options: .backwards),
              let pid = Int32(body[andRange.upperBound...].trimmingCharacters(in: .whitespaces)) else { continue }
        var left = String(body[..<andRange.lowerBound])
        for _ in 0..<3 { if let r = left.range(of: ", ", options: .backwards) { left = String(left[..<r.lowerBound]) } }
        titleToPids[left, default: []].append(pid)
    }
    let allPids = Set(titleToPids.values.flatMap { $0 })
    var rss: [Int32: UInt64] = [:]
    if !allPids.isEmpty {
        let out = run("/bin/ps", ["-o", "pid=,rss=", "-p", allPids.map(String.init).joined(separator: ",")])
        for l in out.split(separator: "\n") {
            let f = l.split(separator: " ")
            if f.count == 2, let pid = Int32(f[0]), let kb = UInt64(f[1]) { rss[pid] = kb * 1024 }
        }
    }
    var tabs = input
    var used: [String: Int] = [:]
    var usersOfPid: [Int32: Int] = [:]
    for i in tabs.indices {
        tabs[i].measured = true
        let key = tabs[i].title
        guard let pids = titleToPids[key] else { continue }
        let n = used[key, default: 0]
        guard n < pids.count else { continue }
        used[key] = n + 1
        let pid = pids[n]
        tabs[i].pid = pid
        tabs[i].mem = rss[pid]
        usersOfPid[pid, default: 0] += 1
    }
    for i in tabs.indices { if let pid = tabs[i].pid { tabs[i].shared = usersOfPid[pid] ?? 1 } }
    return (tabs, nil)
}

func chromeRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
}

/// Returns tabs, or an error string explaining why none could be read.
func fetchChromeTabs() -> (tabs: [ChromeTab], error: String?) {
    guard chromeRunning() else { return ([], "Chrome is not running.") }
    let script = """
    tell application "Google Chrome"
        set out to ""
        repeat with w in windows
            set wid to id of w
            repeat with t in tabs of w
                set out to out & wid & "\\t" & (id of t) & "\\t" & (title of t) & "\\t" & (URL of t) & "\\n"
            end repeat
        end repeat
        return out
    end tell
    """
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let o = Pipe(), e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return ([], "Could not run osascript.") }
    let data = o.fileHandleForReading.readDataToEndOfFile()
    let errData = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8) ?? ""
        if msg.contains("-1743") { return ([], "Allow MemBar to control Chrome in System Settings → Privacy & Security → Automation.") }
        return ([], msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let text = String(data: data, encoding: .utf8) ?? ""
    var tabs: [ChromeTab] = []
    for line in text.split(separator: "\n") {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 4 else { continue }
        tabs.append(ChromeTab(id: "\(f[0]):\(f[1])", windowID: f[0], tabID: f[1], title: f[2], url: f[3]))
    }
    return (tabs, nil)
}

func closeChromeTab(_ t: ChromeTab) {
    guard t.windowID.allSatisfy(\.isNumber), t.tabID.allSatisfy(\.isNumber) else { return }
    run("/usr/bin/osascript", ["-e", "tell application \"Google Chrome\" to close (tab id \(t.tabID) of window id \(t.windowID))"])
}
