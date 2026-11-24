import Foundation
import AppKit

struct DiskItem: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: UInt64
    let isDir: Bool
}

/// (total, available) bytes of the startup disk.
func readDisk() -> (total: UInt64, avail: UInt64) {
    let url = URL(fileURLWithPath: "/")
    let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
    guard let v = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
    return (UInt64(v.volumeTotalCapacity ?? 0), UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0))
}

/// Sizes every direct child (folders via `du`, files via FileManager) of `parent`, biggest first.
/// Slow on big folders: call off the main thread.
func listDir(_ parent: String) -> [DiskItem] {
    var items: [DiskItem] = []
    var seen = Set<String>()
    // macOS du cannot combine -a with -d, so folders come from du...
    let out = run("/usr/bin/du", ["-k", "-d", "1", parent])
    for line in out.split(separator: "\n") {
        let f = line.split(separator: "\t", maxSplits: 1)
        guard f.count == 2, let kb = UInt64(f[0]) else { continue }
        let path = String(f[1])
        if path == parent || path == parent + "/" { continue }
        seen.insert(path)
        items.append(DiskItem(name: (path as NSString).lastPathComponent, path: path, bytes: kb * 1024, isDir: true))
    }
    // ...and loose files from the file system.
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
    if let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: parent), includingPropertiesForKeys: keys, options: []) {
        for u in urls where !seen.contains(u.path) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            items.append(DiskItem(name: u.lastPathComponent, path: u.path, bytes: UInt64(v?.totalFileAllocatedSize ?? 0), isDir: isDir))
        }
    }
    return items.sorted { $0.bytes > $1.bytes }
}

/// Only things inside your home folder or /Applications can be deleted, and never the standard
/// top-level folders themselves (Documents, Library, Application Support, ...).
func canTrash(_ path: String) -> Bool {
    let home = NSHomeDirectory()
    let blocked: Set<String> = [
        home, "/Applications",
        home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads",
        home + "/Movies", home + "/Music", home + "/Pictures", home + "/Public",
        home + "/Applications", home + "/.Trash", home + "/.ssh",
        home + "/Library/Application Support", home + "/Library/Caches", home + "/Library/Containers",
        home + "/Library/Group Containers", home + "/Library/Keychains", home + "/Library/Mobile Documents",
        home + "/Library/Preferences", home + "/Library/Developer",
    ]
    if blocked.contains(path) { return false }
    return path.hasPrefix(home + "/") || path.hasPrefix("/Applications/")
}
