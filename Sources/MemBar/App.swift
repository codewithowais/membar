import SwiftUI

@main
struct MemBarApp: App {
    @StateObject private var model = Model()

    init() {
        setpriority(PRIO_PROCESS, 0, 10)   // lower CPU priority than the apps you are using
        DebugLog.install()
    }

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

// MARK: - Liquid Glass helpers

extension View {
    /// Liquid Glass on macOS 26+, a frosted material everywhere else.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(shape.fill(.ultraThinMaterial))
                .background(shape.fill(tint ?? .clear))
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.6))
        }
    }
}

/// Lets nearby glass shapes blend into each other (macOS 26+).
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    init(spacing: CGFloat = 10, @ViewBuilder _ content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

// MARK: - Animated backdrop

/// Slow drifting colour glows behind the glass, so the glass has something to refract.
/// Drawn as radial gradients on one Canvas that fills the whole panel (no blur, so no hard edges).
/// Runs at 20 fps and only while the panel is on screen, so it stays cheap.
struct AuroraBackground: View {
    let colors: [Color]
    var active = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let w = size.width, h = size.height
                glow(&gc, colors[0], x: w * 0.25 + sin(t / 3.1) * w * 0.18, y: h * 0.18 + cos(t / 4.2) * h * 0.10, r: w * 0.75)
                glow(&gc, colors[1], x: w * 0.80 + cos(t / 3.7) * w * 0.16, y: h * 0.52 + sin(t / 2.9) * h * 0.12, r: w * 0.70)
                glow(&gc, colors[2], x: w * 0.40 + sin(t / 4.6 + 1) * w * 0.20, y: h * 0.90 + cos(t / 3.3) * h * 0.07, r: w * 0.75)
            }
        }
    }

    private func glow(_ gc: inout GraphicsContext, _ c: Color, x: CGFloat, y: CGFloat, r: CGFloat) {
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        gc.fill(Path(ellipseIn: rect),
                with: .radialGradient(Gradient(colors: [c.opacity(0.55), c.opacity(0.0)]),
                                      center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
    }
}

// MARK: - Building blocks

func levelColor(_ f: Double) -> Color { f > 0.9 ? .red : f > 0.75 ? .orange : .green }

struct UsageBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).modifier(NoFocusRing())
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .glass(Capsule())
    }
}

struct PillButton: View {
    var title: String = ""
    var systemImage: String? = nil
    var destructive = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let s = systemImage { Image(systemName: s) }
                if !title.isEmpty { Text(title) }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .foregroundStyle(tint != nil ? Color.white : (destructive && hover ? Color.red : Color.primary))
            .glass(Capsule(), tint: tint ?? (destructive && hover ? Color.red.opacity(0.45) : nil))
            .scaleEffect(hover && enabled ? 1.07 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: hover)
            .opacity(enabled ? 1 : 0.4)
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
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.14 : 0)))
            .scaleEffect(hover ? 1.012 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
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
        Text(big).font(.system(size: 26, weight: .bold, design: .rounded))
            .contentTransition(.numericText())
            .animation(.default, value: big)
        Text(small).font(.callout).foregroundStyle(.secondary)
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

/// Circular gauge with a gradient arc and a number in the middle.
struct Ring: View {
    let fraction: Double
    let color: Color
    let value: String
    let caption: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: 13)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0.001), 1)))
                .stroke(AngularGradient(colors: [color.opacity(0.45), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(fraction, 0.05))),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 6)
            VStack(spacing: 0) {
                Text(value).font(.system(size: 27, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 112)
        .animation(.spring(response: 0.7, dampingFraction: 0.8), value: fraction)
        .animation(.default, value: value)
    }
}

struct SectionHeader: View {
    let title: String
    let trailing: String
    var upper = true

    var body: some View {
        HStack {
            Text(upper ? title.uppercased() : title)
                .font(.caption2.weight(.semibold)).tracking(upper ? 0.8 : 0)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer()
            Text(trailing).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }
}

struct SkeletonRows: View {
    let count: Int
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 11) {
                    RoundedRectangle(cornerRadius: 8).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4).frame(width: CGFloat(120 + (i * 37) % 90), height: 10)
                        RoundedRectangle(cornerRadius: 3).frame(width: 70, height: 6)
                    }
                    Spacer()
                    Capsule().frame(width: 52, height: 10)
                }
                .foregroundStyle(Color.primary.opacity(0.10))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

/// Memory pressure over the last few minutes.
struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let pts = points(in: g.size)
            if pts.count > 2 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: g.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    Circle().fill(color).frame(width: 7, height: 7).position(pts[pts.count - 1])
                        .shadow(color: color, radius: 4)
                }
            } else {
                Text("collecting data…").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let lo = max(0, (values.min() ?? 0) - 0.03)
        let hi = min(1, (values.max() ?? 1) + 0.03)
        let span = max(hi - lo, 0.02)
        return values.enumerated().map { i, v in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                    y: size.height * (1 - CGFloat((v - lo) / span)))
        }
    }
}

// MARK: - Root

enum Tab: String, CaseIterable {
    case memory = "RAM", disk = "Disk", chrome = "Chrome", clean = "Clean"
    var icon: String {
        switch self {
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .chrome: return "globe"
        case .clean: return "sparkles"
        }
    }
}

struct GlassTabBar: View {
    @Binding var tab: Tab
    @Namespace private var ns

    var body: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { tab = t }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.icon).symbolVariant(tab == t ? .fill : .none)
                            Text(t.rawValue)
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tab == t ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if tab == t {
                                Color.clear
                                    .glass(Capsule(), tint: Color.accentColor.opacity(0.35))
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glass(Capsule())
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @AppStorage("membar.tab") private var tabRaw: String = Tab.memory.rawValue
    var tab: Tab { Tab(rawValue: tabRaw) ?? .memory }

    /// Calm mode: no animated backdrop when the Mac is short on memory, in Low Power Mode, or with Reduce Motion on.
    var calm: Bool {
        model.mem.pressure > 0.85
            || ProcessInfo.processInfo.isLowPowerModeEnabled
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "membar.static")
    }

    var auroraColors: [Color] {
        switch tab {
        case .memory: return [.blue, .purple, levelColor(model.mem.pressure)]
        case .disk: return [.teal, .indigo, .mint]
        case .chrome: return [.orange, .pink, .purple]
        case .clean: return [.mint, .green, .cyan]
        }
    }

    var body: some View {
        ZStack {
            AuroraBackground(colors: auroraColors, active: model.panelOpen && !calm)
            VStack(spacing: 12) {
                GlassTabBar(tab: Binding(get: { tab }, set: { tabRaw = $0.rawValue }))
                Group {
                    switch tab {
                    case .memory: MemoryView()
                    case .disk: DiskView()
                    case .chrome: ChromeView()
                    case .clean: CleanView()
                    }
                }
                .id(tab)
                .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                HStack {
                    Label("MemBar 1.1", systemImage: "memorychip").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    PillButton(title: "Quit MemBar") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(14)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 420, height: 620)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            HStack(spacing: 11) {
                if let p = g.appPath {
                    Image(nsImage: IconCache.icon(p)).resizable().frame(width: 26, height: 26)
                } else {
                    Image(systemName: "gearshape.fill").foregroundStyle(.secondary).frame(width: 26, height: 26)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.name).lineLimit(1)
                    Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    UsageBar(fraction: Double(g.bytes) / Double(max(maxBytes, 1)), tint: .accentColor, height: 4)
                }
                Text(fmt(g.bytes)).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
                PillButton(title: "Quit", destructive: true, action: onQuit)
                    .disabled(protectedNames.contains(g.name))
            }
        }
    }
}

struct RamHeader: View {
    let m: MemInfo
    let history: [Double]

    var status: (String, String, Color) {
        if m.pressure > 0.9 { return ("Almost full", "exclamationmark.triangle.fill", .red) }
        if m.pressure > 0.75 { return ("Getting busy", "gauge.with.dots.needle.67percent", .orange) }
        return ("Healthy", "checkmark.seal.fill", .green)
    }

    var body: some View {
        let s = status
        Card {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Ring(fraction: m.pressure, color: levelColor(m.pressure),
                     value: String(format: "%.1f", Double(m.used) / 1_073_741_824),
                     caption: "of \(Int((Double(m.total) / 1_073_741_824).rounded())) GB")
                VStack(alignment: .leading, spacing: 9) {
                    Label(s.0, systemImage: s.1).font(.headline).foregroundStyle(s.2)
                    VStack(alignment: .leading, spacing: 5) {
                        row(.blue, "Apps", m.app)
                        row(.orange, "Wired", m.wired)
                        row(.purple, "Compressed", m.compressed)
                        row(.gray, "Swap", m.swapUsed)
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("MEMORY USE · LAST \(max(1, history.count * 4 / 60)) MIN")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Sparkline(values: history, color: levelColor(m.pressure)).frame(height: 34)
            }
            .padding(.top, 4)
            }
        }
    }

    private func row(_ c: Color, _ name: String, _ v: UInt64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(name).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(fmt(v)).font(.caption.weight(.medium)).monospacedDigit()
        }
        .frame(width: 150)
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: Model
    @State private var search = ""

    var body: some View {
        let rows = model.groups.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        VStack(alignment: .leading, spacing: 10) {
            RamHeader(m: model.mem, history: model.memHistory)
            SearchField(prompt: "Filter apps", text: $search)
            SectionHeader(title: "Apps by memory", trailing: "\(rows.count) apps")
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

// MARK: - Chrome

func hostHue(_ s: String) -> Double {
    var h = 0
    for u in s.unicodeScalars { h = (h &* 31 &+ Int(u.value)) % 360 }
    return Double(h) / 360
}

func memColor(_ bytes: UInt64) -> Color {
    let mb = Double(bytes) / 1_048_576
    return mb < 150 ? .green : mb < 400 ? .orange : .red
}

struct TabAvatar: View {
    let host: String
    var icon: NSImage? = nil
    var body: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                .padding(5)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
        } else {
            letterAvatar
        }
    }

    @ViewBuilder private var letterAvatar: some View {
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let h = hostHue(clean)
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color(hue: h, saturation: 0.5, brightness: 0.98),
                                              Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.78)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(clean.first ?? "•").uppercased())
                .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
        .shadow(color: Color(hue: h, saturation: 0.6, brightness: 0.8).opacity(0.4), radius: 4, y: 2)
    }
}

struct MemChip: View {
    let mem: UInt64?
    let measured: Bool

    var body: some View {
        if let m = mem {
            Text(fmt(m)).font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(memColor(m))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glass(Capsule(), tint: memColor(m).opacity(0.25))
        } else if measured {
            Text("Suspended · 0 MB").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .glass(Capsule())
        } else {
            Text("—").font(.callout).foregroundStyle(.tertiary)
        }
    }
}

struct TabRow: View {
    let t: ChromeTab
    let maxMem: UInt64
    let onClose: () -> Void

    var body: some View {
        HoverRow {
            HStack(spacing: 11) {
                TabAvatar(host: t.host, icon: t.favicon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title.isEmpty ? t.host : t.title).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(t.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if t.shared > 1 { Text("· shared by \(t.shared) tabs").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let m = t.mem {
                        UsageBar(fraction: Double(m) / Double(max(maxMem, 1)), tint: memColor(m), height: 4)
                    }
                }
                Spacer(minLength: 6)
                MemChip(mem: t.mem, measured: t.measured)
                PillButton(systemImage: "xmark", destructive: true, action: onClose).help("Close tab")
            }
        }
    }
}

struct ShareBar: View {
    let tabs: [ChromeTab]

    var body: some View {
        // One segment per live process, sized by its share of the total.
        var seen = Set<Int32>()
        let parts = tabs.compactMap { t -> (String, UInt64)? in
            guard let p = t.pid, let m = t.mem, seen.insert(p).inserted else { return nil }
            return (t.host, m)
        }.sorted { $0.1 > $1.1 }
        let total = max(parts.reduce(UInt64(0)) { $0 + $1.1 }, 1)
        return GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    let clean = part.0.hasPrefix("www.") ? String(part.0.dropFirst(4)) : part.0
                    Capsule().fill(Color(hue: hostHue(clean), saturation: 0.55, brightness: 0.9))
                        .frame(width: max(4, (g.size.width - CGFloat(parts.count) * 2) * CGFloat(part.1) / CGFloat(total)))
                }
                if parts.isEmpty { Capsule().fill(Color.primary.opacity(0.10)) }
            }
        }
        .frame(height: 9)
    }
}

struct ChromeView: View {
    @EnvironmentObject var model: Model
    @State private var search = ""

    var totalMem: UInt64 {
        var seen = Set<Int32>()
        var sum: UInt64 = 0
        for t in model.tabs { if let p = t.pid, let m = t.mem, seen.insert(p).inserted { sum += m } }
        return sum
    }

    var body: some View {
        let measured = model.tabs.contains { $0.measured }
        let live = model.tabs.filter { $0.mem != nil }.count
        let suspended = model.tabs.filter { $0.measured && $0.mem == nil }.count
        let maxMem = model.tabs.compactMap(\.mem).max() ?? 1
        let rows = model.tabs
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.mem ?? 0) > ($1.mem ?? 0) }
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 11) {
                    if measured { Stat(fmt(totalMem), "used by \(model.tabs.count) tabs") }
                    else { Stat("\(model.tabs.count)", "open tabs") }
                    if measured {
                        ShareBar(tabs: model.tabs)
                        HStack(spacing: 14) {
                            Legend(color: .green, text: "\(live) active")
                            Legend(color: .gray, text: "\(suspended) suspended")
                        }
                    }
                    GlassGroup(spacing: 8) {
                        HStack(spacing: 8) {
                            PillButton(title: model.measuring ? "Measuring…" : "Measure every tab", systemImage: "memorychip", tint: .accentColor) { model.measureTabs() }
                                .disabled(model.measuring)
                            PillButton(title: "Reload", systemImage: "arrow.clockwise") { model.refreshTabs() }
                        }
                    }
                    if !measured {
                        Text("Tap Measure to see how many MB each tab uses. Suspended tabs show 0 MB.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let e = model.tabsError { Text(e).font(.caption2).foregroundStyle(.orange) }
                }
            }
            SearchField(prompt: "Filter tabs", text: $search)
            SectionHeader(title: "Tabs by memory", trailing: "\(rows.count) tabs")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { t in
                        TabRow(t: t, maxMem: maxMem) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.close(t) } }
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: rows.map(\.id))
            }
            Text("Measuring briefly opens Chrome's Task Manager, so Chrome comes to the front and this panel closes. Reopen it to see the numbers.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshTabs() }
        .onChange(of: model.panelOpen) { _, open in if open { model.refreshTabs() } }
    }
}

// MARK: - Clean

struct CleanView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.mint)
                        .symbolEffect(.bounce, value: model.lastFreed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cleaner").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("Caches, logs, build files and Trash").font(.caption).foregroundStyle(.secondary)
                    }
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
                                Text(item.name).font(.body.weight(.medium))
                                Text(item.note).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.size == 0 ? (item.id == "trash" ? "via Finder" : "–") : fmtDisk(item.size))
                                .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if let f = model.lastFreed {
                Label("Freed \(fmtDisk(f))", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .glass(Capsule(), tint: Color.green.opacity(0.25))
            }
            Spacer()
            let canClean = !model.scanning && model.items.contains { $0.selected && ($0.size > 0 || $0.id == "trash") }
            Button { model.clean() } label: {
                Label("Clean selected", systemImage: "wand.and.stars")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .glass(Capsule(), tint: Color.green.opacity(0.7))
            }
            .buttonStyle(.plain)
            .opacity(canClean ? 1 : 0.4)
            .disabled(!canClean)
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
            HStack(spacing: 11) {
                Image(systemName: it.isDir ? "folder.fill" : "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(it.isDir ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(it.name).lineLimit(1)
                        UsageBar(fraction: Double(it.bytes) / Double(max(maxBytes, 1)), tint: Color.accentColor, height: 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 4) {
                    if it.pending { ProgressView().controlSize(.mini) }
                    if !(it.pending && it.bytes == 0) {
                        Text(fmtDisk(it.bytes)).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                            .opacity(it.pending ? 0.55 : 1)
                    }
                }
                .frame(width: 84, alignment: .trailing)
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

    var statusText: String {
        if model.diskScanning {
            return model.diskScanTotal > 0 ? "measuring \(model.diskScanDone)/\(model.diskScanTotal) folders…" : "listing…"
        }
        return "\(model.diskItems.count) items"
    }

    var body: some View {
        let used = model.diskTotal > model.diskAvail ? model.diskTotal - model.diskAvail : 0
        let frac = model.diskTotal == 0 ? 0 : Double(used) / Double(model.diskTotal)
        VStack(alignment: .leading, spacing: 10) {
            Card {
                HStack(spacing: 16) {
                    Ring(fraction: frac, color: levelColor(frac), value: "\(Int((frac * 100).rounded()))%", caption: "used")
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(fmtDisk(model.diskAvail)) free", systemImage: "internaldrive.fill")
                            .font(.headline).foregroundStyle(levelColor(frac))
                        Text("\(fmtDisk(used)) used of \(fmtDisk(model.diskTotal))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            GlassGroup(spacing: 6) {
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
            }
            SectionHeader(title: shortPath, trailing: statusText, upper: false)
            if model.diskScanning && model.diskScanTotal > 0 {
                UsageBar(fraction: Double(model.diskScanDone) / Double(max(model.diskScanTotal, 1)), tint: .accentColor, height: 3)
                    .padding(.horizontal, 8)
            } else if !model.diskScanning && model.diskItems.isEmpty {
                Text("Nothing found here, or macOS blocked access. Allow MemBar in Privacy & Security → Files and Folders.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if model.diskScanning && model.diskItems.isEmpty {
                SkeletonRows(count: 7).frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.diskItems) { it in
                            DiskRow(it: it, maxBytes: model.diskItems.first?.bytes ?? 1,
                                    open: { if it.isDir { model.openDisk(it.path) } },
                                    trash: { model.trash(it) })
                        }
                    }
                }
            }
            if let m = model.diskMessage { Text(m).font(.caption2).foregroundStyle(.orange) }
        }
        // The panel is kept alive between openings, so onAppear only fires once. Rescan every time it opens.
        .onChange(of: model.panelOpen) { _, open in
            if open && !model.diskScanning && model.mem.pressure < 0.92
                && Date().timeIntervalSince(model.diskScanAt ?? .distantPast) > 20 {
                model.scanDisk()
            }
        }
        .onAppear {
            if model.diskItems.isEmpty && !model.diskScanning {
                model.openDisk(model.diskPath)     // cached results first, then a fresh scan
            } else if !model.diskScanning && model.mem.pressure < 0.92
                        && Date().timeIntervalSince(model.diskScanAt ?? .distantPast) > 120 {
                model.scanDisk()
            }
        }
    }
}
