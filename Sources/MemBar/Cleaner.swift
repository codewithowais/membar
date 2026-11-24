import Foundation

struct CleanItem: Identifiable {
    let id: String
    let name: String
    let note: String
    let url: URL
    var size: UInt64 = 0
    var selected: Bool
}

func defaultCleanItems() -> [CleanItem] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
        CleanItem(id: "caches", name: "User caches", note: "~/Library/Caches. Apps rebuild these.", url: home.appendingPathComponent("Library/Caches"), selected: true),
        CleanItem(id: "logs", name: "User logs", note: "~/Library/Logs", url: home.appendingPathComponent("Library/Logs"), selected: true),
        CleanItem(id: "derived", name: "Xcode DerivedData", note: "Build products. Xcode rebuilds them.", url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), selected: true),
        CleanItem(id: "trash", name: "Trash", note: "Permanent. Emptied by Finder, so hidden .folders go too.", url: home.appendingPathComponent(".Trash"), selected: false),
    ]
}

func dirSize(_ url: URL) -> UInt64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
    guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: UInt64 = 0
    for case let u as URL in en {
        if let v = try? u.resourceValues(forKeys: Set(keys)), let s = v.totalFileAllocatedSize { total += UInt64(s) }
    }
    return total
}

/// Deletes the contents of a folder (not the folder itself). Returns bytes freed.
func clearContents(of url: URL) -> UInt64 {
    let fm = FileManager.default
    let before = dirSize(url)
    guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return 0 }
    for i in items { try? fm.removeItem(at: i) }
    let after = dirSize(url)
    return before > after ? before - after : 0
}

/// MemBar cannot read ~/.Trash without Full Disk Access, so ask Finder to empty it instead.
func emptyTrashViaFinder() {
    run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"])
}
