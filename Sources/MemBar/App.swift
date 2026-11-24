import SwiftUI

@main
struct MemBarApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(model)
        } label: {
            Image(systemName: "memorychip")
            Text(String(format: "%.1f GB", Double(model.mem.used) / 1_073_741_824))
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Shared building blocks

func levelColor(_ f: Double) -> Color { f > 0.9 ? .red : f > 0.75 ? .orange : .green }

struct UsageBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(tint)
                    .frame(width: max(height, g.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) { content.focusEffectDisabled() } else { content }
    }
}

struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).modifier(NoFocusRing())
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
    }
}

struct PillButton: View {
    var title: String = ""
    var systemImage: String? = nil
    var destructive = false
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let s = systemImage { Image(systemName: s) }
                if !title.isEmpty { Text(title) }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(destructive && hover ? Color.red.opacity(0.18) : Color.primary.opacity(hover ? 0.14 : 0.08)))
            .foregroundStyle(destructive && hover ? Color.red : Color.primary)
            .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct HoverRow<Content: View>: View {
    let content: Content
    @State private var hover = false
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
    }
}

enum IconCache {
    static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

func Stat(_ big: String, _ small: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(big).font(.system(size: 24, weight: .semibold, design: .rounded))
        Text(small).font(.callout).foregroundStyle(.secondary)
    }
}

// MARK: - Root

enum Tab: String, CaseIterable { case memory = "RAM", disk = "Disk", chrome = "Chrome", clean = "Clean" }

struct ContentView: View {
    @EnvironmentObject var model: Model
    @State private var tab: Tab = .memory

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            Group {
                switch tab {
                case .memory: MemoryView()
                case .disk: DiskView()
                case .chrome: ChromeView()
                case .clean: CleanView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack {
                Text("MemBar").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Quit MemBar") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 420, height: 600)
    }
}

// MARK: - RAM

struct RamRow: View {
    let g: ProcGroup
    let maxBytes: UInt64
    let onQuit: () -> Void

    var caption: String {
        let n = "\(g.pids.count) process" + (g.pids.count == 1 ? "" : "es")
        if g.name == "Claude Code engine" { return n + " · runs your Claude session" }
        if protectedNames.contains(g.name) { return n + " · protected" }
        return g.isApp ? n : n + " · background service, may restart"
    }

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                if let p = g.appPath {
                    Image(nsImage: IconCache.icon(p)).resizable().frame(width: 24, height: 24)
                } else {
                    Image(systemName: "gearshape.fill").foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.name).lineLimit(1)
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    UsageBar(fraction: Double(g.bytes) / Double(max(maxBytes, 1)), tint: .accentColor, height: 3)
                }
                Text(fmt(g.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                PillButton(title: "Quit", destructive: true, action: onQuit)
                    .disabled(protectedNames.contains(g.name))
            }
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: Model
    @State private var search = ""

    var body: some View {
        let m = model.mem
        let rows = model.groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Stat(fmt(m.used), "of \(fmt(m.total)) used")
                        Spacer()
                        Text("Swap \(fmt(m.swapUsed))").font(.caption).foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: m.pressure, tint: levelColor(m.pressure))
                    HStack(spacing: 14) {
                        Legend(color: .blue, text: "App \(fmt(m.app))")
                        Legend(color: .orange, text: "Wired \(fmt(m.wired))")
                        Legend(color: .purple, text: "Compressed \(fmt(m.compressed))")
                    }
                }
            }
            SearchField(prompt: "Filter apps", text: $search)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows.prefix(40)) { g in
                        RamRow(g: g, maxBytes: model.groups.first?.bytes ?? 1) { model.quit(g) }
                    }
                }
            }
        }
    }
}

struct Legend: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Chrome

struct TabRow: View {
    let t: ChromeTab
    let onClose: () -> Void

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title.isEmpty ? t.host : t.title).lineLimit(1)
                    Text(t.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let m = t.mem {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(fmt(m)).font(.callout.weight(.semibold)).monospacedDigit()
                        if t.shared > 1 { Text("shared by \(t.shared)").font(.caption2).foregroundStyle(.secondary) }
                    }
                } else if t.measured {
                    Text("suspended").font(.caption2).foregroundStyle(.secondary)
                }
                PillButton(title: "Close", destructive: true, action: onClose)
            }
        }
    }
}

struct ChromeView: View {
    @EnvironmentObject var model: Model
    @State private var search = ""

    var body: some View {
        let live = model.tabs.filter { $0.mem != nil }.count
        let rows = model.tabs
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.mem ?? 0) > ($1.mem ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Stat("\(model.tabs.count)", "open tabs")
                        Spacer()
                        if model.tabs.contains(where: { $0.measured }) {
                            Text("\(live) using memory").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        PillButton(title: model.measuring ? "Measuring…" : "Measure memory", systemImage: "memorychip") { model.measureTabs() }
                            .disabled(model.measuring)
                        PillButton(title: "Reload", systemImage: "arrow.clockwise") { model.refreshTabs() }
                    }
                    if let e = model.tabsError { Text(e).font(.caption2).foregroundStyle(.orange) }
                }
            }
            SearchField(prompt: "Filter tabs", text: $search)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { t in TabRow(t: t) { model.close(t) } }
                }
            }
            Text("Measure memory briefly opens Chrome's Task Manager, so Chrome comes to the front and this panel closes. Reopen it to see the numbers.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshTabs() }
    }
}

// MARK: - Clean

struct CleanView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    Stat("Cleaner", "caches, logs, Trash")
                    Spacer()
                    PillButton(title: model.scanning ? "Working…" : "Scan", systemImage: "arrow.clockwise") { model.scan() }
                        .disabled(model.scanning)
                }
            }
            ForEach($model.items) { $item in
                Card {
                    Toggle(isOn: $item.selected) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.note).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.size == 0 ? (item.id == "trash" ? "via Finder" : "–") : fmtDisk(item.size))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if let f = model.lastFreed { Text("Freed \(fmtDisk(f))").font(.caption).foregroundStyle(.green) }
            Spacer()
            Button { model.clean() } label: {
                Text("Clean selected").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.scanning || !model.items.contains { $0.selected && ($0.size > 0 || $0.id == "trash") })
        }
        .onAppear { if model.items.allSatisfy({ $0.size == 0 }) { model.scan() } }
    }
}

// MARK: - Disk

struct DiskRow: View {
    let it: DiskItem
    let maxBytes: UInt64
    let open: () -> Void
    let trash: () -> Void

    var body: some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: it.isDir ? "folder.fill" : "doc.fill")
                    .foregroundStyle(it.isDir ? Color.accentColor : Color.secondary)
                    .frame(width: 22)
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(it.name).lineLimit(1)
                        UsageBar(fraction: Double(it.bytes) / Double(max(maxBytes, 1)), tint: Color.accentColor.opacity(0.7), height: 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(fmtDisk(it.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                PillButton(systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)])
                }
                .help("Show in Finder")
                PillButton(systemImage: "trash", destructive: true, action: trash)
                    .disabled(!canTrash(it.path))
                    .help("Move to Trash")
            }
        }
    }
}

struct DiskView: View {
    @EnvironmentObject var model: Model

    var shortPath: String { model.diskPath.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        let used = model.diskTotal > model.diskAvail ? model.diskTotal - model.diskAvail : 0
        let frac = model.diskTotal == 0 ? 0 : Double(used) / Double(model.diskTotal)
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Stat(fmtDisk(used), "of \(fmtDisk(model.diskTotal)) used")
                        Spacer()
                        Text("\(fmtDisk(model.diskAvail)) free").font(.caption).foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: frac, tint: levelColor(frac))
                }
            }
            HStack(spacing: 6) {
                PillButton(systemImage: "arrow.up") { model.diskUp() }
                    .disabled(model.diskPath == NSHomeDirectory() || model.diskPath == "/Applications")
                PillButton(title: "Home") { model.openDisk(NSHomeDirectory()) }
                PillButton(title: "Apps") { model.openDisk("/Applications") }
                PillButton(title: "Library") { model.openDisk(NSHomeDirectory() + "/Library") }
                PillButton(title: "Downloads") { model.openDisk(NSHomeDirectory() + "/Downloads") }
                Spacer()
                PillButton(systemImage: "arrow.clockwise") { model.scanDisk() }.disabled(model.diskScanning)
            }
            Text(shortPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if model.diskScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning, big folders take a little while…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if model.diskItems.isEmpty {
                Text("Nothing found here, or macOS blocked access. Allow MemBar in Privacy & Security → Files and Folders.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.diskItems) { it in
                        DiskRow(it: it, maxBytes: model.diskItems.first?.bytes ?? 1,
                                open: { if it.isDir { model.openDisk(it.path) } },
                                trash: { model.trash(it) })
                    }
                }
            }
            if let m = model.diskMessage { Text(m).font(.caption2).foregroundStyle(.orange) }
        }
        .onAppear {
            if !model.diskScanning && (model.diskItems.isEmpty || Date().timeIntervalSince(model.diskScanAt ?? .distantPast) > 120) {
                model.scanDisk()
            }
        }
    }
}
