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
    /// True while the panel is open (MemBar is the active app). Everything heavy is gated on this.
    @Published var panelOpen = false
    /// Keys of actions in progress ("q:<app>" quit, "t:<path>" delete, "c:<tab>" close tab); buttons show a loader.
    @Published var busy: Set<String> = []
    @Published var cleaning = false

    /// Not @Published on purpose: appending to it must not re-render the UI while the panel is closed.
    var memHistory: [Double] = []

    private var timer: Timer?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelOpen = true; self?.refresh() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panelOpen = false; self?.releaseWhenClosed() }
        }
        // Belt and braces: the panel is also "open" whenever one of our own windows is key.
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            let cls = (n.object as? NSWindow)?.className ?? ""
            guard !cls.contains("StatusBar"), !cls.contains("TUI") else { return }
            Task { @MainActor in self?.panelOpen = true; self?.refresh() }
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] n in
            let cls = (n.object as? NSWindow)?.className ?? ""
            guard !cls.contains("StatusBar"), !cls.contains("TUI") else { return }
            Task { @MainActor in self?.panelOpen = false }
        }
        sampleMemory()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 2   // lets macOS batch our wake-ups with others
    }

    /// Free what only the open panel needs (icons for 40 rows etc.) so MemBar stays small while idle.
    private func releaseWhenClosed() {
        if !groups.isEmpty { groups = [] }
        IconCache.clear()
    }

    /// Cheap (a couple of syscalls, no process spawned). Runs always, to feed the menu bar number and the graph.
    private func sampleMemory() {
        let m = readMemory()
        memHistory.append(m.pressure)
        if memHistory.count > 90 { memHistory.removeFirst() }
        // With the panel closed, only republish when the menu bar text (0.1 GB steps) would change.
        let step: UInt64 = 107_374_182
        if panelOpen || m.used / step != mem.used / step { mem = m }
        else if panelOpen == false { /* keep the old value, nothing on screen to update */ }
    }

    func refresh() {
        sampleMemory()
        // If we somehow missed an "opened" event, a key window or active app still means the panel is showing.
        if !panelOpen && (NSApp.isActive || NSApp.keyWindow != nil) { panelOpen = true }
        guard panelOpen else { return }
        Task.detached(priority: .utility) {
            let g = readProcGroups()
            let d = readDisk()
            await MainActor.run { self.groups = g; self.diskTotal = d.total; self.diskAvail = d.avail }
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

    @Published var diskScanDone = 0
    @Published var diskScanTotal = 0
    private var diskCache: [String: [DiskItem]] = DiskCache.load()
    private var scanTask: Task<Void, Never>?
    private var scanID = 0

    func openDisk(_ path: String) {
        diskPath = path
        // Show what we already know straight away; the rescan then refreshes it in the background.
        diskItems = (diskCache[path] ?? []).map { var i = $0; i.pending = i.isDir; return i }
        scanDisk()
    }

    func diskUp() {
        guard diskPath != NSHomeDirectory(), diskPath != "/Applications" else { return }
        openDisk((diskPath as NSString).deletingLastPathComponent)
    }

    /// Lists the folder instantly, then measures sub-folders three at a time. Every result shows up
    /// the moment it is ready, so you never stare at an empty screen.
    func scanDisk() {
        scanTask?.cancel()
        scanID += 1
        let id = scanID
        let path = diskPath
        let cached = diskCache[path] ?? []
        diskScanning = true
        diskScanDone = 0
        diskScanTotal = 0
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let disk = readDisk()
            var items = quickList(path)
            // Show last time's sizes (dimmed) while the fresh ones are calculated.
            let old = Dictionary(cached.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
            for i in items.indices where items[i].pending { items[i].bytes = old[items[i].path] ?? 0 }
            items = sortedItems(items)
            let todo = items.filter { $0.pending }.sorted { $0.bytes < $1.bytes }.map(\.path)
            let snapshot = items
            await MainActor.run {
                guard let self, self.scanID == id else { return }
                self.diskTotal = disk.total; self.diskAvail = disk.avail
                self.diskItems = snapshot
                self.diskScanTotal = todo.count
            }
            if todo.count > 120 {
                // Huge folder (thousands of sub-folders): one `du` pass is far lighter than a process per folder.
                let sizes = await duChildren(path)
                if Task.isCancelled { return }
                await MainActor.run { self?.applyBatch(scanID: id, sizes: sizes) }
            } else {
                await withTaskGroup(of: (String, UInt64?).self) { group in
                    var next = 0
                    while next < min(2, todo.count) {
                        let p = todo[next]; next += 1
                        group.addTask { (p, await duSize(p)) }
                    }
                    while let (p, size) = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        await MainActor.run { self?.applySize(scanID: id, itemPath: p, bytes: size) }
                        if next < todo.count {
                            let q = todo[next]; next += 1
                            group.addTask { (q, await duSize(q)) }
                        }
                    }
                }
            }
            if Task.isCancelled { return }
            await MainActor.run { self?.finishScan(id: id, path: path) }
        }
    }

    private func applySize(scanID id: Int, itemPath: String, bytes: UInt64?) {
        guard scanID == id, let idx = diskItems.firstIndex(where: { $0.path == itemPath }) else { return }
        var it = diskItems[idx]
        if let b = bytes { it.bytes = b }
        it.pending = false
        diskItems[idx] = it
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { diskItems = sortedItems(diskItems) }
        diskScanDone += 1
    }

    private func applyBatch(scanID id: Int, sizes: [String: UInt64]) {
        guard scanID == id else { return }
        for i in diskItems.indices where diskItems[i].pending {
            if let b = sizes[diskItems[i].path] { diskItems[i].bytes = b }
            diskItems[i].pending = false
        }
        diskScanDone = diskScanTotal
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { diskItems = sortedItems(diskItems) }
    }

    private func finishScan(id: Int, path: String) {
        guard scanID == id else { return }
        diskScanning = false
        diskScanAt = Date()
        diskCache[path] = diskItems.map { var i = $0; i.pending = false; return i }
        DiskCache.save(diskCache)
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
        let key = "t:" + it.path
        busy.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            let err: String? = {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: it.path), resultingItemURL: nil); return nil }
                catch { return error.localizedDescription }
            }()
            await MainActor.run {
                guard let self else { return }
                self.busy.remove(key)
                if let err {
                    self.diskMessage = "Could not delete \(it.name): \(err)"
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.diskItems.removeAll { $0.path == it.path } }
                    self.diskMessage = "Moved \(it.name) to Trash. Empty the Trash (Clean tab) to get the space back."
                }
            }
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
        let key = "c:" + t.id
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task.detached(priority: .utility) { [weak self] in
            closeChromeTab(t)
            await MainActor.run {
                self?.busy.remove(key)
                self?.tabs.removeAll { $0.id == t.id }
                self?.refreshTabs()
            }
        }
    }

    /// Asks the app to quit, shows a loader on its button until it is really gone, and offers a force quit if it refuses.
    func quit(_ g: ProcGroup) {
        let key = "q:" + g.id
        guard !busy.contains(key) else { return }
        busy.insert(key)
        MemBar.quit(g)
        Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if g.pids.allSatisfy({ kill($0, 0) != 0 }) { break }
            }
            busy.remove(key)
            refresh()
            let alive = g.pids.filter { kill($0, 0) == 0 }
            guard g.isApp, !alive.isEmpty else { return }
            let a = NSAlert()
            a.messageText = "\(g.name) did not quit"
            a.informativeText = "It may be showing a dialog or saving. Force quitting can lose unsaved work."
            a.addButton(withTitle: "Force quit")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                for pid in alive { kill(pid, SIGKILL) }
                try? await Task.sleep(nanoseconds: 800_000_000)
                refresh()
            }
        }
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
        cleaning = true
        Task.detached(priority: .utility) {
            var freed: UInt64 = 0
            for i in sel { if i.id == "trash" { emptyTrashViaFinder() } else { freed += clearContents(of: i.url) } }
            await MainActor.run { self.cleaning = false; self.lastFreed = freed; self.scan() }
        }
    }
}
