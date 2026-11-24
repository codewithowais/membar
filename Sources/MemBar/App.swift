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
            switch tab {
            case .memory: MemoryView()
            case .disk: DiskView()
            case .chrome: ChromeView()
            case .clean: CleanView()
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit MemBar") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(width: 400, height: 640)
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: Model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let m = model.mem
            HStack {
                Text("\(fmt(m.used)) of \(fmt(m.total)) used").font(.headline)
                Spacer()
                Text("Swap \(fmt(m.swapUsed))").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(m.pressure, 1)).tint(m.pressure > 0.85 ? .red : m.pressure > 0.7 ? .orange : .green)
            Text("App \(fmt(m.app)) · Wired \(fmt(m.wired)) · Compressed \(fmt(m.compressed))")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Filter apps", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }.prefix(40)) { g in
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(g.name).lineLimit(1)
                                Text("\(g.pids.count) process\(g.pids.count == 1 ? "" : "es")" + (g.isApp ? "" : " · system service, restarts itself")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(fmt(g.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            Button("Quit") { model.quit(g) }
                                .disabled(protectedNames.contains(g.name))
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }
}

struct ChromeView: View {
    @EnvironmentObject var model: Model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.tabs.count) tabs").font(.headline)
                Spacer()
                Button(model.measuring ? "Measuring…" : "Measure memory") { model.measureTabs() }.disabled(model.measuring)
                Button("Reload") { model.refreshTabs() }
            }
            if let e = model.tabsError { Text(e).font(.caption).foregroundStyle(.orange) }
            TextField("Filter tabs", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.tabs
                        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
                        .sorted { ($0.mem ?? 0) > ($1.mem ?? 0) }) { t in
                        HStack {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(t.title.isEmpty ? t.host : t.title).lineLimit(1)
                                Text(t.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let m = t.mem {
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(fmt(m)).monospacedDigit().bold()
                                    if t.shared > 1 { Text("shared by \(t.shared) tabs").font(.caption2).foregroundStyle(.secondary) }
                                }
                            } else if t.measured {
                                Text("no process (suspended)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Button("Close") { model.close(t) }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            Text("Measure memory briefly opens Chrome's Task Manager to read which process each tab uses, so Chrome comes to the front and this panel closes. Reopen it to see the numbers.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshTabs() }
    }
}

struct CleanView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cleaner").font(.headline)
                Spacer()
                Button(model.scanning ? "Working…" : "Scan") { model.scan() }.disabled(model.scanning)
            }
            ForEach($model.items) { $item in
                Toggle(isOn: $item.selected) {
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name)
                            Text(item.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.size == 0 ? (item.id == "trash" ? "via Finder" : "–") : fmtDisk(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if let f = model.lastFreed { Text("Freed \(fmtDisk(f))").font(.caption).foregroundStyle(.green) }
            Spacer()
            Button("Clean selected") { model.clean() }
                .buttonStyle(.borderedProminent)
                .disabled(model.scanning || !model.items.contains { $0.selected && ($0.size > 0 || $0.id == "trash") })
        }
        .onAppear { if model.items.allSatisfy({ $0.size == 0 }) { model.scan() } }
    }
}

struct DiskView: View {
    @EnvironmentObject var model: Model

    var shortPath: String { model.diskPath.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let used = model.diskTotal > model.diskAvail ? model.diskTotal - model.diskAvail : 0
            let frac = model.diskTotal == 0 ? 0 : Double(used) / Double(model.diskTotal)
            HStack {
                Text("\(fmtDisk(used)) of \(fmtDisk(model.diskTotal)) used").font(.headline)
                Spacer()
                Text("\(fmtDisk(model.diskAvail)) free").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(frac, 1)).tint(frac > 0.9 ? .red : frac > 0.75 ? .orange : .green)
            HStack(spacing: 6) {
                Button { model.diskUp() } label: { Image(systemName: "arrow.up") }
                    .disabled(model.diskPath == NSHomeDirectory() || model.diskPath == "/Applications")
                Button("Home") { model.openDisk(NSHomeDirectory()) }
                Button("Apps") { model.openDisk("/Applications") }
                Button("Library") { model.openDisk(NSHomeDirectory() + "/Library") }
                Button("Downloads") { model.openDisk(NSHomeDirectory() + "/Downloads") }
                Spacer()
                Button(model.diskScanning ? "…" : "Rescan") { model.scanDisk() }.disabled(model.diskScanning)
            }
            Text(shortPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if model.diskScanning { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Scanning, big folders take a few seconds…").font(.caption2).foregroundStyle(.secondary) } }
            else if model.diskItems.isEmpty { Text("Nothing found here, or macOS blocked access. Allow MemBar in Privacy & Security → Files and Folders.").font(.caption2).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.diskItems) { it in
                        HStack(spacing: 6) {
                            Image(systemName: it.isDir ? "folder" : "doc").foregroundStyle(.secondary).frame(width: 16)
                            Button {
                                if it.isDir { model.openDisk(it.path) }
                            } label: {
                                Text(it.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            Text(fmtDisk(it.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) } label: { Image(systemName: "magnifyingglass") }
                                .help("Show in Finder")
                            Button { model.trash(it) } label: { Image(systemName: "trash") }
                                .disabled(!canTrash(it.path))
                                .help("Move to Trash")
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            if let m = model.diskMessage { Text(m).font(.caption2).foregroundStyle(.orange) }
            Text("Click a folder to open it. Trash icon moves to Trash (recoverable); protected system folders are greyed out.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { if !model.diskScanning && (model.diskItems.isEmpty || Date().timeIntervalSince(model.diskScanAt ?? .distantPast) > 120) { model.scanDisk() } }
    }
}
