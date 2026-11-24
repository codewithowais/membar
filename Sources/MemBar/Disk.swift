import Foundation
import AppKit

struct DiskItem: Identifiable, Codable {
    var id: String { path }
    let name: String
    let path: String
    var bytes: UInt64
    let isDir: Bool
    /// True while this folder's size is still being (re)calculated. Not saved to the cache.
    var pending = false

    enum CodingKeys: String, CodingKey { case name, path, bytes, isDir }
}

/// (total, available) bytes of the startup disk.
func readDisk() -> (total: UInt64, avail: UInt64) {
    let url = URL(fileURLWithPath: "/")
    let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
    guard let v = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
    return (UInt64(v.volumeTotalCapacity ?? 0), UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0))
}

/// Media libraries: touching them makes macOS ask for Photos/Music access over and over.
private let skippedSuffixes = [".photoslibrary", ".musiclibrary", ".tvlibrary"]

/// Instant listing of a folder: files get their real size straight away, folders are marked
/// `pending` (size 0) and get filled in later by `duSize`. Takes milliseconds.
func quickList(_ parent: String) -> [DiskItem] {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: parent), includingPropertiesForKeys: keys, options: []) else { return [] }
    var items: [DiskItem] = []
    for u in urls {
        let v = try? u.resourceValues(forKeys: Set(keys))
        let isDir = (v?.isDirectory ?? false) && !(v?.isSymbolicLink ?? false)
        let skipped = skippedSuffixes.contains { u.lastPathComponent.hasSuffix($0) }
        items.append(DiskItem(name: u.lastPathComponent, path: u.path,
                              bytes: isDir ? 0 : UInt64(v?.totalFileAllocatedSize ?? 0),
                              isDir: isDir, pending: isDir && !skipped))
    }
    return sortedItems(items)
}

/// Biggest first; folders still being measured sink to the bottom (they sit between "known" and "unknown").
func sortedItems(_ items: [DiskItem]) -> [DiskItem] {
    items.sorted { a, b in
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Size of one folder via `du -sk`. Runs at background priority and the `du` process is killed
/// if the surrounding task is cancelled (for example when you open another folder).
func duSize(_ path: String) async -> UInt64? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    p.arguments = ["-sk", "-I", "*.photoslibrary", "-I", "*.musiclibrary", "-I", "*.tvlibrary", path]
    p.qualityOfService = .background
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt64?, Never>) in
            DispatchQueue.global(qos: .background).async {
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                if let kb = text.split(separator: "\t").first.flatMap({ UInt64($0) }) { cont.resume(returning: kb * 1024) }
                else { cont.resume(returning: nil) }
            }
        }
    } onCancel: {
        if p.isRunning { p.terminate() }
    }
}

// MARK: - Cache (so a folder you have seen before opens instantly)

enum DiskCache {
    static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MemBar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("disk-cache.json")
    }

    static func load() -> [String: [DiskItem]] {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode([String: [DiskItem]].self, from: d) else { return [:] }
        return c
    }

    static func save(_ cache: [String: [DiskItem]]) {
        // Keep the file small: at most 40 folders, 300 items each.
        var trimmed: [String: [DiskItem]] = [:]
        for (k, v) in cache.prefix(40) { trimmed[k] = Array(v.prefix(300)) }
        if let d = try? JSONEncoder().encode(trimmed) { try? d.write(to: url, options: .atomic) }
    }
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
