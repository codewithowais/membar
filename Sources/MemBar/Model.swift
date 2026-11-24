import SwiftUI
import AppKit

@MainActor
final class Model: ObservableObject {
    @Published var mem = MemInfo()
    @Published var groups: [ProcGroup] = []
    @Published var tabs: [ChromeTab] = []
    @Published var tabsError: String? = nil
    @Published var items: [CleanItem] = defaultCleanItems()
    @Published var scanning = false
    @Published var lastFreed: UInt64? = nil

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached {
            let m = readMemory()
            let g = readProcGroups()
            let d = readDisk()
            await MainActor.run { self.mem = m; self.groups = g; self.diskTotal = d.total; self.diskAvail = d.avail }
        }
    }

    @Published var measuring = false
    @Published var diskTotal: UInt64 = 0
    @Published var diskAvail: UInt64 = 0
    @Published var diskItems: [DiskItem] = []
    @Published var diskScanning = false
    @Published var diskPath = NSHomeDirectory()
    @Published var diskMessage: String? = nil
    var diskScanAt: Date? = nil

    func openDisk(_ path: String) {
        diskPath = path
        scanDisk()
    }

    func diskUp() {
        guard diskPath != NSHomeDirectory(), diskPath != "/Applications" else { return }
        openDisk((diskPath as NSString).deletingLastPathComponent)
    }

    func scanDisk() {
        diskScanning = true
        let path = diskPath
        Task.detached {
            let d = readDisk()
            await MainActor.run { self.diskTotal = d.total; self.diskAvail = d.avail }
            let items = listDir(path)
            await MainActor.run {
                if self.diskPath == path { self.diskItems = items; self.diskScanAt = Date() }
                self.diskScanning = false
            }
        }
    }

    func trash(_ it: DiskItem) {
        guard canTrash(it.path) else {
            diskMessage = "\(it.name) is protected and cannot be deleted here."
            return
        }
        let a = NSAlert()
        a.messageText = "Move \"\(it.name)\" (\(fmtDisk(it.bytes))) to Trash?"
        a.informativeText = it.path + "\n\nYou can still restore it from the Trash until you empty it."
        a.alertStyle = .warning
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: it.path), resultingItemURL: nil)
            diskItems.removeAll { $0.path == it.path }
            diskMessage = "Moved \(it.name) to Trash. Empty the Trash (Clean tab) to get the space back."
        } catch {
            diskMessage = "Could not delete \(it.name): \(error.localizedDescription)"
        }
    }

    func refreshTabs() {
        let old = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Task.detached {
            var r = fetchChromeTabs()
            for i in r.tabs.indices {
                if let o = old[r.tabs[i].id] {
                    r.tabs[i].mem = o.mem; r.tabs[i].pid = o.pid; r.tabs[i].shared = o.shared; r.tabs[i].measured = o.measured
                }
            }
            await MainActor.run { self.tabs = r.tabs; self.tabsError = r.error }
        }
    }

    func measureTabs() {
        guard !measuring else { return }
        measuring = true
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        let current = tabs
        Task.detached {
            let r = measureChromeTabs(current)
            await MainActor.run { self.tabs = r.tabs; self.tabsError = r.error; self.measuring = false }
        }
    }

    func close(_ t: ChromeTab) {
        tabs.removeAll { $0.id == t.id }
        Task.detached { closeChromeTab(t); await MainActor.run { self.refreshTabs() } }
    }

    func quit(_ g: ProcGroup) {
        MemBar.quit(g)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    func scan() {
        scanning = true
        let current = items
        Task.detached {
            var out = current
            for i in out.indices { out[i].size = dirSize(out[i].url) }
            await MainActor.run { self.items = out; self.scanning = false }
        }
    }

    func clean() {
        let sel = items.filter { $0.selected && ($0.size > 0 || $0.id == "trash") }
        guard !sel.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = sel.allSatisfy({ $0.size == 0 }) ? "Empty the Trash?" : "Delete \(fmtDisk(sel.reduce(0) { $0 + $1.size })) of files?"
        alert.informativeText = sel.map(\.name).joined(separator: ", ") + (sel.contains { $0.id == "trash" } ? "\n\nTrash is emptied permanently." : "")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        scanning = true
        Task.detached {
            var freed: UInt64 = 0
            for i in sel { if i.id == "trash" { emptyTrashViaFinder() } else { freed += clearContents(of: i.url) } }
            await MainActor.run { self.lastFreed = freed; self.scan() }
        }
    }
}
