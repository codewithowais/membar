import Foundation
import Darwin

struct MemInfo {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

func readMemory() -> MemInfo {
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    var s = vm_statistics64_data_t()
    let r = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    var m = MemInfo()
    m.total = ProcessInfo.processInfo.physicalMemory
    guard r == KERN_SUCCESS else { return m }
    let page = UInt64(getpagesize())
    let internalPages = UInt64(s.internal_page_count)
    let purgeable = UInt64(s.purgeable_count)
    m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
    m.wired = UInt64(s.wire_count) * page
    m.compressed = UInt64(s.compressor_page_count) * page
    m.used = m.app + m.wired + m.compressed
    var sw = xsw_usage()
    var len = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &sw, &len, nil, 0) == 0 { m.swapUsed = sw.xsu_used }
    return m
}

struct ProcGroup: Identifiable {
    let id: String
    var name: String
    var bytes: UInt64
    var pids: [Int32]
    var isApp: Bool = false
    var appPath: String? = nil
}

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.qualityOfService = .background   // never compete with the apps you are using
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func groupName(_ path: String) -> String {
    if path.contains("/claude-code/") { return "Claude Code engine" }
    let parts = path.components(separatedBy: "/")
    if let app = parts.first(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
    return parts.last ?? path
}

/// Lists your processes straight from the kernel (no `ps` process is spawned, which matters most
/// when the Mac is short on memory) and groups them by app.
func readProcGroups() -> [ProcGroup] {
    let uid = getuid()
    var pids = [pid_t](repeating: 0, count: 4096)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    guard n > 0 else { return [] }
    var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    var map: [String: ProcGroup] = [:]
    for i in 0..<min(n, pids.count) {
        let pid = pids[i]
        if pid <= 0 { continue }
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize, bsd.pbi_uid == uid else { continue }
        var ti = proc_taskinfo()
        let tiSize = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize else { continue }
        guard proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
        let path = String(cString: pathBuf)
        let name = groupName(path)
        var appPath: String? = nil
        if !path.contains("/claude-code/"), let r = path.range(of: ".app/") { appPath = String(path[..<r.lowerBound]) + ".app" }
        var g = map[name] ?? ProcGroup(id: name, name: name, bytes: 0, pids: [], isApp: appPath != nil, appPath: appPath)
        g.bytes += ti.pti_resident_size
        g.pids.append(pid)
        map[name] = g
    }
    return map.values.sorted { $0.bytes > $1.bytes }
}

let protectedNames: Set<String> = ["Finder", "Dock", "loginwindow", "WindowServer", "SystemUIServer", "MemBar", "Claude Code engine", "launchd", "ps", "zsh", "bash"]

func quit(_ g: ProcGroup, force: Bool = false) {
    for pid in g.pids { kill(pid, force ? SIGKILL : SIGTERM) }
}

func fmt(_ b: UInt64) -> String {
    let gb = Double(b) / 1_073_741_824
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    return String(format: "%.0f MB", Double(b) / 1_048_576)
}

/// Disk sizes use decimal units (1 GB = 1,000,000,000 bytes), the same as Finder and System Settings.
func fmtDisk(_ b: UInt64) -> String {
    let gb = Double(b) / 1_000_000_000
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    return String(format: "%.0f MB", Double(b) / 1_000_000)
}
