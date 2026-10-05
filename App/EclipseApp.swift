import SwiftUI
import NetworkExtension
import Foundation
import AVFoundation
import PhotosUI
import CoreImage
import CoreImage.CIFilterBuiltins

@main
struct EclipseApp: App {
    @StateObject private var store = Store()
    @StateObject private var vpn = VPNController()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor { $0.userInterfaceStyle == .light
            ? UIColor(hex: 0xF5F2FF) : UIColor(hex: 0x0D0B1A) }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITextView.appearance().backgroundColor = .clear
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(vpn)
                .environmentObject(AppSettings.shared)
                .preferredColorScheme(AppSettings.shared.appearance.scheme)
        }
    }
}

struct AppearanceModifier: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared
    func body(content: Content) -> some View {
        content.preferredColorScheme(settings.appearance.scheme)
    }
}

struct RootView: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var store: Store
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            HomeView(onPickServer: { tab = 1 })
                .background(AppBackground())
                .tabItem { Label("Главная", systemImage: "shield.lefthalf.filled") }
                .tag(0)
            ServersView()
                .background(AppBackground())
                .tabItem { Label("Серверы", systemImage: "globe") }
                .tag(1)
            SettingsView()
                .background(AppBackground())
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(2)
        }
        .accentColor(Theme.accentLight)
        .onAppear {
            vpn.load()
            Task { await store.autoRefresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            vpn.load()   // пересинхронизируем статус: расширение могло упасть, пока приложение спало
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Тема приложения: системная / тёмная / светлая.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Системная"
        case .dark: return "Тёмная"
        case .light: return "Светлая"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum Theme {
    /// Цвет, который сам меняется между тёмной и светлой темой.
    static func dyn(_ dark: UIColor, _ light: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .light ? light : dark })
    }
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color { dyn(UIColor(hex: dark), UIColor(hex: light)) }

    static let bg = dyn(0x0D0B1A, 0xF5F2FF)
    static let bg2 = dyn(0x140F28, 0xEBE6FA)
    static let card = dyn(0x15121F, 0xFFFFFF)
    static let accent = Color(hex: 0x7C5CFC)
    static let accentDark = Color(hex: 0x6040E0)
    static let accentLight = dyn(0xC4ABFF, 0x5B3FD6)   // акцентный текст/иконки
    static let accent2 = Color(hex: 0xA07CFF)
    static let muted = dyn(0x9B90CC, 0x6B6190)
    /// Основной цвет текста.
    static let text = dyn(0xFFFFFF, 0x1B1635)
    static let border = dyn(UIColor(white: 1, alpha: 0.09), UIColor(hex: 0x1B1635, alpha: 0.12))
    /// Полупрозрачная заливка поверх фона (замена Color.white.opacity(x)).
    static func fg(_ a: Double) -> Color {
        dyn(UIColor(white: 1, alpha: a), UIColor(hex: 0x1B1635, alpha: a * 1.4))
    }
    /// Поля ввода.
    static let field = dyn(UIColor(white: 0, alpha: 0.28), UIColor(hex: 0x1B1635, alpha: 0.06))
    /// Карточки поверх анимированного фона.
    static let glass = dyn(UIColor(hex: 0x0F0C20, alpha: 0.82), UIColor(white: 1, alpha: 0.88))
}

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var vpn: VPNController
    @State private var float = false
    var body: some View {
        ZStack {
            Theme.bg
            GeometryReader { g in
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0x7C5CFC, opacity: 0.15), .clear],
                                             center: .center, startRadius: 0, endRadius: 210))
                        .frame(width: 420, height: 420)
                        .blur(radius: 40)
                        .scaleEffect(float ? 1.05 : 1)
                        .position(x: 110, y: 70)
                        .offset(y: float ? -30 : 0)
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0xA07CFF, opacity: 0.10), .clear],
                                             center: .center, startRadius: 0, endRadius: 180))
                        .frame(width: 360, height: 360)
                        .blur(radius: 40)
                        .scaleEffect(float ? 1 : 1.05)
                        .position(x: g.size.width - 60, y: g.size.height - 180)
                        .offset(y: float ? 0 : -30)
                }
            }
            SceneCanvas(connected: vpn.status == .connected)
            if colorScheme == .dark {
                Color.black.opacity(0.22)
                RadialGradient(colors: [Color.black.opacity(0.40), .clear],
                               center: .center, startRadius: 0, endRadius: 340)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { float = true }
        }
    }
}

private struct WaveLine {
    let yFrac: Double, yJitter: Double, phase: Double, speed: Double
    let amp: Double, freq: Double, opacity: Double
}

private struct CubeSpec {
    let x: Double, y: Double, s: Double, spin: Double, floatDur: Double
}

private struct SeededRNG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0x1000000)
    }
}

final class SceneMotion {
    static let shared = SceneMotion()
    static let idle = 0.25
    static let peak = 5.0
    static let cruise = 0.7
    static let rampTime = 1.4
    static let rampTau = 0.55
    static let settleTau = 3.5
    static let idleTau = 1.5
    private var phase = 0.0
    private var speed = SceneMotion.idle
    private var last: Double?
    private var connectedAt: Double?
    private var wasConnected = false
    func update(now: Double, connected: Bool) -> Double {
        if connected && !wasConnected { connectedAt = now }
        if !connected { connectedAt = nil }
        wasConnected = connected
        let dt = min(max(now - (last ?? now), 0), 0.25)
        last = now
        let target: Double, tau: Double
        if let ca = connectedAt {
            if now - ca < SceneMotion.rampTime { target = SceneMotion.peak; tau = SceneMotion.rampTau }
            else { target = SceneMotion.cruise; tau = SceneMotion.settleTau }
        } else {
            target = SceneMotion.idle; tau = SceneMotion.idleTau
        }
        speed += (target - speed) * (1 - exp(-dt / tau))
        phase += speed * dt
        return phase
    }
}

struct SceneCanvas: View {
    var connected: Bool = false
    private static let lines: [WaveLine] = {
        var r = SeededRNG(state: 20260404)
        return (0..<16).map { i in
            WaveLine(yFrac: Double(i) / 16, yJitter: r.next() * 15,
                     phase: r.next() * 2 * Double.pi,
                     speed: (0.0025 + r.next() * 0.004) * 60,
                     amp: 16 + r.next() * 35,
                     freq: 0.0035 + r.next() * 0.003,
                     opacity: 0.04 + r.next() * 0.08)
        }
    }()
    private static let cubes: [CubeSpec] = [
        CubeSpec(x: 0.06, y: 0.12, s: 90,  spin: 34, floatDur: 9),
        CubeSpec(x: 0.84, y: 0.10, s: 130, spin: 42, floatDur: 11),
        CubeSpec(x: 0.10, y: 0.62, s: 130, spin: 48, floatDur: 12),
        CubeSpec(x: 0.88, y: 0.74, s: 90,  spin: 36, floatDur: 10),
        CubeSpec(x: 0.46, y: 0.90, s: 60,  spin: 26, floatDur: 7)
    ]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let spin = SceneMotion.shared.update(now: t, connected: connected)
                Self.drawLines(&ctx, size, t)
                Self.drawCubes(&ctx, size, t, spin)
            }
        }
        .allowsHitTesting(false)
    }
    private static func drawLines(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = Double(size.width), h = Double(size.height)
        for l in lines {
            var path = Path()
            let baseY = h * l.yFrac + l.yJitter
            let ph = l.phase + l.speed * t
            var x = 0.0
            path.move(to: CGPoint(x: 0, y: baseY + sin(ph) * l.amp))
            while x <= w {
                path.addLine(to: CGPoint(x: x, y: baseY + sin(x * l.freq + ph) * l.amp))
                x += 4
            }
            ctx.stroke(path,
                       with: .color(Color(red: 140 / 255, green: 100 / 255, blue: 1, opacity: l.opacity)),
                       lineWidth: 1)
        }
    }
    private static func rotate(_ v: (Double, Double, Double),
                               _ ax: Double, _ ay: Double, _ az: Double) -> (Double, Double, Double) {
        var (x, y, z) = v
        let cz = cos(az), sz = sin(az)
        (x, y) = (x * cz - y * sz, x * sz + y * cz)
        let cy = cos(ay), sy = sin(ay)
        (x, z) = (x * cy + z * sy, -x * sy + z * cy)
        let cx = cos(ax), sx = sin(ax)
        (y, z) = (y * cx - z * sx, y * sx + z * cx)
        return (x, y, z)
    }
    private static func drawCubes(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ spin: Double) {
        let persp = 900.0
        let ox = Double(size.width) / 2, oy = Double(size.height) / 2
        let signs: [(Double, Double, Double)] = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
                                                  (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
        let faces: [[Int]] = [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [3, 2, 6, 7], [0, 3, 7, 4], [1, 2, 6, 5]]
        let count = size.width < 700 ? 3 : cubes.count
        for (i, c) in cubes.prefix(count).enumerated() {
            let fp = (t + Double(i) * 1.3) / c.floatDur
            let ph = fp - floor(fp)
            let tri = ph < 0.5 ? ph * 2 : (1 - ph) * 2
            let eased = tri * tri * (3 - 2 * tri)
            let q = ((spin + Double(i) * 5) / c.spin).truncatingRemainder(dividingBy: 1)
            let ax = 2 * Double.pi * q, ay = 2 * Double.pi * q, az = Double.pi * q
            let h = c.s / 2
            let cx = c.x * Double(size.width) + h
            let cy = c.y * Double(size.height) + h - 34 * eased
            var pts: [(CGPoint, Double)] = []
            for sg in signs {
                let r = rotate((sg.0 * h, sg.1 * h, sg.2 * h), ax, ay, az)
                let k = persp / (persp - r.2)
                pts.append((CGPoint(x: ox + (cx + r.0 - ox) * k, y: oy + (cy + r.1 - oy) * k), r.2))
            }
            let order = faces.sorted { a, b in
                a.map { pts[$0].1 }.reduce(0, +) < b.map { pts[$0].1 }.reduce(0, +)
            }
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: Color(hex: 0x7C5CFC, opacity: 0.40), radius: 9, x: 0, y: 0))
                for f in order {
                    var path = Path()
                    path.move(to: pts[f[0]].0)
                    for idx in f.dropFirst() { path.addLine(to: pts[idx].0) }
                    path.closeSubpath()
                    let r = path.boundingRect
                    let grad = Gradient(colors: [Color(hex: 0xA07CFF, opacity: 0.20),
                                                 Color(hex: 0x7C5CFC, opacity: 0.06)])
                    layer.fill(path, with: .linearGradient(grad,
                                                           startPoint: CGPoint(x: r.minX, y: r.minY),
                                                           endPoint: CGPoint(x: r.maxX, y: r.maxY)))
                    layer.stroke(path, with: .color(Color(hex: 0xC4ABFF, opacity: 0.45)), lineWidth: 1)
                }
            }
        }
    }
}

struct Logo: View {
    var body: some View {
        Text("Eclipse")
            .font(.system(size: 22, weight: .bold))
            .kerning(-0.5)
            .foregroundColor(Theme.text)
            .frame(maxWidth: .infinity)
            .legible()
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.accentLight)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.accent.opacity(0.18)))
    }
}

extension View {
    func card(selected: Bool = false) -> some View {
        self
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 22).fill(Theme.glass))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
    }
    func legible() -> some View {
        shadow(color: Theme.dyn(UIColor(white: 0, alpha: 0.65), UIColor.clear), radius: 6, x: 0, y: 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Theme.accent, Theme.accentDark],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(Theme.text)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fg(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct SpinRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.03)) { tl in
            let angle = tl.date.timeIntervalSinceReferenceDate * 220
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Theme.accentLight, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(angle))
        }
    }
}

struct IconCircle: View {
    let systemName: String
    var busy: Bool = false
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.18))
            if busy { SpinRing() } else {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accentLight)
            }
        }
        .frame(width: 36, height: 36)
    }
}

// Одна волна от кнопки — плавно расходится и гаснет
struct PulseRing: View {
    let trigger: Bool
    @State private var active = false
    var body: some View {
        Circle()
            .stroke(Theme.accentLight.opacity(active ? 0 : 0.30), lineWidth: 1.2)
            .frame(width: 150, height: 150)
            .scaleEffect(active ? 2.0 : 1.0)
            .onChange(of: trigger) { newValue in
                guard newValue else { return }
                active = false
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 1.6)) { active = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { active = false }
            }
    }
}
// MARK: - Ping display / protocol

enum PingDisplay: String, Codable, CaseIterable, Identifiable {
    case time, dots, bar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .time: return "Время"
        case .dots: return "Точки"
        case .bar: return "Шкала"
        }
    }
}

struct SubGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var servers: [Server] = []
    var updatedAt: Date?
    var used: Int64?
    var total: Int64?
    var expire: Date?
    var supportURL: String?
    var webURL: String?

    var updateIntervalHours: Int? = nil
    var pingDisplayRaw: String? = nil
    var pingProtocolRaw: String? = nil
    var tunnelDNS: [String]? = nil

    var pingDisplayOverride: PingDisplay? {
        get { pingDisplayRaw.flatMap { PingDisplay(rawValue: $0) } }
        set { pingDisplayRaw = newValue?.rawValue }
    }
    var pingProtocolOverride: PingProtocol? {
        get { pingProtocolRaw.flatMap { PingProtocol(rawValue: $0) } }
        set { pingProtocolRaw = newValue?.rawValue }
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var groups: [SubGroup] = [] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }
    @Published var refreshing: Set<UUID> = []
    @Published var pingingGroups: Set<UUID> = []
    @Published var pings: [UUID: Int] = [:]
    @Published var message: String?

    private struct Saved: Codable {
        var groups: [SubGroup]
        var selectedID: UUID?
    }
    private struct OldSaved: Codable {
        var servers: [Server]
        var selectedID: UUID?
        var subscriptionURL: String
    }
    private let key = "eclipse.store.v3"
    private let legacyKey = "eclipse.store.v2"
    private let oldKey = "encore.store.v1"

    init() {
        if let data = KeychainStore.load(forKey: key),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            groups = s.groups
            selectedID = s.selectedID
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let s = try? JSONDecoder().decode(Saved.self, from: data) {
            groups = s.groups; selectedID = s.selectedID
            save()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } else if let data = UserDefaults.standard.data(forKey: oldKey),
                  let o = try? JSONDecoder().decode(OldSaved.self, from: data) {
            if !o.servers.isEmpty {
                let isSub = !o.subscriptionURL.isEmpty
                let name = isSub ? (URL(string: o.subscriptionURL)?.host ?? "Подписка") : "Мои серверы"
                groups = [SubGroup(name: name, url: o.subscriptionURL, servers: o.servers)]
            }
            selectedID = o.selectedID
            save()
            UserDefaults.standard.removeObject(forKey: oldKey)
        }
    }

    private func save() {
        let saved = Saved(groups: groups, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(saved) {
            KeychainStore.save(data, forKey: key)
        }
    }

    var allServers: [Server] { groups.flatMap { $0.servers } }
    var selected: Server? { allServers.first { $0.id == selectedID } ?? allServers.first }

    private func fixSelection() {
        if !allServers.contains(where: { $0.id == selectedID }) {
            selectedID = allServers.first?.id
        }
    }

    func removeServer(_ id: UUID) {
        for i in groups.indices { groups[i].servers.removeAll { $0.id == id } }
        fixSelection()
    }
    func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        fixSelection()
    }
    func renameServer(_ id: UUID, to newName: String) {
        for i in groups.indices {
            for j in groups[i].servers.indices where groups[i].servers[j].id == id {
                groups[i].servers[j].name = newName
            }
        }
    }
    func updateServer(_ id: UUID, with newServer: Server, newLink: String) {
        for i in groups.indices {
            for j in groups[i].servers.indices where groups[i].servers[j].id == id {
                var s = newServer
                s.id = id
                s.link = newLink
                groups[i].servers[j] = s
            }
        }
    }
    func updateGroupSettings(_ groupID: UUID,
                             name: String?,
                             url: String?,
                             updateIntervalHours: Int?,
                             pingDisplay: PingDisplay?,
                             pingProtocol: PingProtocol?,
                             tunnelDNS: [String]?) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if let name = name, !name.isEmpty { groups[i].name = name }
        if let url = url { groups[i].url = url }
        groups[i].updateIntervalHours = updateIntervalHours
        groups[i].pingDisplayOverride = pingDisplay
        groups[i].pingProtocolOverride = pingProtocol
        groups[i].tunnelDNS = tunnelDNS
    }

    private func addManual(_ server: Server) {
        if let i = groups.firstIndex(where: { $0.url.isEmpty }) {
            groups[i].servers.append(server)
        } else {
            groups.append(SubGroup(name: "Мои серверы", url: "", servers: [server]))
        }
        selectedID = server.id
    }

    @MainActor
    func add(_ input: String) async -> Bool {
        message = nil
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let single = LinkParser.parse(text) { addManual(single); return true }
        let decoded = text.removingPercentEncoding ?? text
        for p in ["https://", "http://"] {
            if let r = decoded.range(of: p) { text = String(decoded[r.lowerBound...]); break }
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            message = "Не похоже на ссылку подписки или сервера"
            return false
        }
        if let existing = groups.first(where: { $0.url == text }) {
            return await refresh(existing.id)
        }
        let g = SubGroup(name: url.host ?? "Подписка", url: text)
        groups.append(g)
        let ok = await refresh(g.id)
        if !ok { groups.removeAll { $0.id == g.id } }
        return ok
    }

    private func profileTitle(_ response: URLResponse?) -> String? {
        guard let h = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "profile-title") else { return nil }
        var t = h
        if t.lowercased().hasPrefix("base64:") {
            t = LinkParser.decodeBase64(String(t.dropFirst(7))) ?? t
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    @MainActor
    @discardableResult
    func refresh(_ groupID: UUID) async -> Bool {
        guard let g = groups.first(where: { $0.id == groupID }),
              !g.url.isEmpty, let url = URL(string: g.url) else { return false }
        refreshing.insert(groupID)
        message = nil
        defer { refreshing.remove(groupID) }
        do {
            var req = URLRequest(url: url)
            AppSettings.shared.apply(to: &req)
            let (data, response) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8) ?? ""
            var seen = Set<String>()
            var parsed = LinkParser.parseSubscription(text).filter { seen.insert($0.link).inserted }
            if parsed.isEmpty { message = "В подписке не найдено серверов"; return false }
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return false }
            let old = groups[i].servers
            parsed = parsed.map { (item: Server) -> Server in
                var n = item
                if let o = old.first(where: { $0.link == item.link }) { n.id = o.id }
                return n
            }
            let selectedLink = selected?.link
            groups[i].servers = parsed
            groups[i].updatedAt = Date()
            if let http = response as? HTTPURLResponse {
                let info = Store.parseUserInfo(http.value(forHTTPHeaderField: "subscription-userinfo"))
                groups[i].used = info.used; groups[i].total = info.total; groups[i].expire = info.expire
                groups[i].supportURL = http.value(forHTTPHeaderField: "support-url")
                groups[i].webURL = http.value(forHTTPHeaderField: "profile-web-page-url")
            }
            if let t = profileTitle(response) { groups[i].name = t }
            if !allServers.contains(where: { $0.id == selectedID }) {
                selectedID = allServers.first(where: { $0.link == selectedLink })?.id ?? allServers.first?.id
            }
            if !GeoDat.available {
                Task.detached(priority: .utility) {
                    do {
                        try await GeoDat.download(
                            ip: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
                            site: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
                        )
                    } catch { SharedLog.write("[app] geo download failed") }
                }
            }
            return true
        } catch {
            message = "Ошибка загрузки: \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    func refreshAll() async {
        let ids = groups.filter { !$0.url.isEmpty }.map { $0.id }
        for id in ids { _ = await refresh(id) }
    }

    struct UserInfo { var used: Int64?; var total: Int64?; var expire: Date? }

    static func parseUserInfo(_ header: String?) -> UserInfo {
        var u = UserInfo()
        guard let header = header else { return u }
        var up: Double = 0, down: Double = 0, hasUsage = false
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let n = Double(kv[1]) else { continue }
            switch kv[0].lowercased() {
            case "upload": up = n; hasUsage = true
            case "download": down = n; hasUsage = true
            case "total": if n > 0 { u.total = Int64(n) }
            case "expire": if n > 0 { u.expire = Date(timeIntervalSince1970: n) }
            default: break
            }
        }
        if hasUsage { u.used = Int64(up + down) }
        return u
    }

    @MainActor
    func autoRefresh() async {
        let globalHours = AppSettings.shared.updateHours
        let globalEnabled = AppSettings.shared.autoUpdate
        let ids = groups.filter { g in
            guard !g.url.isEmpty else { return false }
            let enabled = globalEnabled || (g.updateIntervalHours != nil)
            guard enabled else { return false }
            let hours = g.updateIntervalHours ?? globalHours
            return Date().timeIntervalSince(g.updatedAt ?? .distantPast) > TimeInterval(hours) * 3600
        }.map { $0.id }
        for id in ids { _ = await refresh(id) }
    }

    @MainActor
    func pingAll(_ groupID: UUID) async {
        guard let g = groups.first(where: { $0.id == groupID }), !g.servers.isEmpty else { return }
        pingingGroups.insert(groupID)
        let mode = g.pingProtocolOverride ?? AppSettings.shared.pingProtocol
        let servers = g.servers
        await withTaskGroup(of: (UUID, Int).self) { group in
            for s in servers {
                group.addTask {
                    let ms = await Store.measure(s, mode: mode)
                    return (s.id, ms ?? -1)
                }
            }
            for await (id, ms) in group {
                await MainActor.run { self.pings[id] = ms }
            }
        }
        pingingGroups.remove(groupID)
    }

    @MainActor
    func pingSingle(_ server: Server) async {
        let g = groups.first { $0.servers.contains(where: { $0.id == server.id }) }
        let mode = g?.pingProtocolOverride ?? AppSettings.shared.pingProtocol
        let ms = await Store.measure(server, mode: mode)
        self.pings[server.id] = ms ?? -1
    }

    /// Пинг с учётом выбранного протокола. Для HTTP-режимов https включается
    /// по security сервера (tls/reality) или по стандартным TLS-портам.
    static func measure(_ s: Server, mode: PingProtocol) async -> Int? {
        let sec = (s.security ?? "").lowercased()
        let tls: Bool? = (sec == "tls" || sec == "reality") ? true : nil
        return await Pinger.ping(host: s.host, port: s.port, mode: mode,
                                 udpBased: s.isUDPBased, useTLS: tls, timeout: 4)
    }
}

// MARK: - VPNController

final class VPNController: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var error: String?
    @Published var connectedAt: Date? {
        didSet {
            if let d = connectedAt {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "vpn.connectedAt")
            } else {
                UserDefaults.standard.removeObject(forKey: "vpn.connectedAt")
            }
        }
    }
    @Published var killSwitch: Bool = UserDefaults.standard.bool(forKey: "killSwitch") {
        didSet { UserDefaults.standard.set(killSwitch, forKey: "killSwitch") }
    }
    private var manager: NETunnelProviderManager?
    private var previous: NEVPNStatus = .disconnected
    private var sawActive = false
    private var userStopped = false
    private var pendingServer: Server?

    init() {
        if let ts = UserDefaults.standard.object(forKey: "vpn.connectedAt") as? TimeInterval {
            self.connectedAt = Date(timeIntervalSince1970: ts)
        }
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, let conn = self.manager?.connection else { return }
            let new = conn.status
            self.previous = new
            self.status = new
            switch new {
            case .connecting, .connected, .reasserting: self.sawActive = true
            default: break
            }
            self.haptic(for: new)
            if new == .connected {
                self.error = nil
                if self.connectedAt == nil { self.connectedAt = Date() }
            } else if new == .disconnected {
                self.connectedAt = nil
            }
            if new == .disconnected && self.sawActive {
                self.sawActive = false
                if !self.userStopped { self.collectError(conn) }
            }
            if new == .disconnected, let next = self.pendingServer {
                self.pendingServer = nil
                self.start(next)
            }
        }
    }

    private func haptic(for status: NEVPNStatus) {
        switch status {
        case .connecting:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .connected:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .disconnected:
            if previous == .connected || previous == .disconnecting {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        default: break
        }
    }

    private func collectError(_ conn: NEVPNConnection) {
        let d = AppGroup.defaults
        if let msg = d.string(forKey: TunnelKeys.lastError) {
            d.removeObject(forKey: TunnelKeys.lastError)
            error = Sanitizer.clean(msg)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        let fallback = "Туннель остановился без сообщения об ошибке."
        if #available(iOS 16.0, *) {
            conn.fetchLastDisconnectError { [weak self] err in
                DispatchQueue.main.async {
                    if let err = err as NSError? {
                        self?.error = Sanitizer.clean(err.localizedDescription)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    } else { self?.error = fallback }
                }
            }
        } else { error = fallback }
    }

    var embeddedExtensionID: String? {
        guard let url = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
              let appex = items.first(where: { $0.pathExtension == "appex" }) else { return nil }
        return Bundle(url: appex)?.bundleIdentifier
    }
    var tunnelBundleID: String {
        embeddedExtensionID ?? ((Bundle.main.bundleIdentifier ?? "") + ".tunnel")
    }

    func load() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.manager = managers?.first
                self.status = self.manager?.connection.status ?? .disconnected
                self.previous = self.status
                if self.status == .connected {
                    if self.connectedAt == nil { self.connectedAt = Date() }
                } else { self.connectedAt = nil }
            }
        }
    }

    var isActive: Bool {
        switch status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    // Удаляет все сохранённые VPN-профили Eclipse.
    // Используется кнопкой «Удалить все VPN-профили» в настройках.
    func removeAllProfiles() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            let group = DispatchGroup()
            for m in managers ?? [] {
                group.enter()
                m.removeFromPreferences { _ in group.leave() }
            }
            group.notify(queue: .main) {
                self.manager = nil
                self.status = .disconnected
                self.previous = .disconnected
                self.connectedAt = nil
                self.error = nil
            }
        }
    }

    private func stopTunnel() {
        userStopped = true
        if let m = manager, m.isOnDemandEnabled {
            m.isOnDemandEnabled = false
            m.saveToPreferences { _ in m.connection.stopVPNTunnel() }
        } else { manager?.connection.stopVPNTunnel() }
    }

    func switchServer(_ server: Server) {
        guard isActive else { return }
        pendingServer = server
        stopTunnel()
    }

    func toggle(server: Server?) {
        if isActive { pendingServer = nil; stopTunnel(); return }
        guard let server = server else { error = "Сначала добавьте сервер"; return }
        start(server)
    }

    private func start(_ server: Server) {
        error = nil
        userStopped = false
        sawActive = false
        SharedLog.clear()
        SharedLog.write("[app] старт: \(server.protocolLabel) \(server.host):\(server.port)")
        let profile: XrayProfile
        do {
            profile = try XrayConfigBuilder.build(for: server, options: AppSettings.shared.tunnelOptions, logPath: nil)
        } catch {
            self.error = Sanitizer.clean(error.localizedDescription)
            return
        }
        SharedLog.write("[app] конфиг Xray собран (\(profile.json.count) байт)")

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            let m = managers?.first ?? NETunnelProviderManager()
            // Если прошлый туннель завис в connecting/disconnecting, startVPNTunnel молча
            // игнорируется - отсюда "больше не подключается". Сначала добиваем старый.
            if [.connecting, .reasserting, .disconnecting, .connected].contains(m.connection.status) {
                m.connection.stopVPNTunnel()
                self.waitDisconnected(m.connection, deadline: Date().addingTimeInterval(4)) {
                    self.configureAndStart(m, server: server, profile: profile)
                }
                return
            }
            self.configureAndStart(m, server: server, profile: profile)
        }
    }

    private func waitDisconnected(_ conn: NEVPNConnection, deadline: Date, then done: @escaping () -> Void) {
        if conn.status == .disconnected || conn.status == .invalid || Date() > deadline {
            DispatchQueue.main.async(execute: done); return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            self.waitDisconnected(conn, deadline: deadline, then: done)
        }
    }

    private var connectToken = UUID()

    /// Если за 25 с туннель не поднялся - гасим его и показываем ошибку, а не крутим вечный спиннер.
    private func armWatchdog() {
        let token = UUID(); connectToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self = self, self.connectToken == token,
                  self.status == .connecting || self.status == .reasserting else { return }
            SharedLog.write("[app] watchdog: туннель не поднялся за 25 с")
            self.error = "Не удалось подключиться за 25 секунд. Проверьте сервер и сеть."
            self.userStopped = true
            self.manager?.connection.stopVPNTunnel()
        }
    }

    private func configureAndStart(_ m: NETunnelProviderManager, server: Server, profile: XrayProfile) {
        let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleID
            proto.serverAddress = server.host
            proto.providerConfiguration = [
                TunnelKeys.xrayConfig: profile.json,
                TunnelKeys.socksPort: profile.socksPort,
                TunnelKeys.socksUser: profile.socksUser,
                TunnelKeys.socksPass: profile.socksPass,
                TunnelKeys.serverHost: server.host,
                TunnelKeys.serverPort: server.port,
                TunnelKeys.options: AppSettings.shared.tunnelOptions.json,
                TunnelKeys.core: profile.core,
                TunnelKeys.udpServer: server.isUDPBased
            ]
            proto.includeAllNetworks = self.killSwitch
            proto.excludeLocalNetworks = true
            m.protocolConfiguration = proto
            m.localizedDescription = "Eclipse"
            m.isEnabled = true
            let onDemand = AppSettings.shared.onDemand
            m.isOnDemandEnabled = onDemand
            m.onDemandRules = onDemand ? [NEOnDemandRuleConnect() as NEOnDemandRule] : []
            m.saveToPreferences { saveError in
                if let saveError = saveError {
                    DispatchQueue.main.async { self.error = Sanitizer.clean(saveError.localizedDescription) }
                    return
                }
                m.loadFromPreferences { _ in
                    DispatchQueue.main.async { self.manager = m }
                    do {
                        try m.connection.startVPNTunnel()
                        DispatchQueue.main.async { self.armWatchdog() }
                    } catch {
                        DispatchQueue.main.async { self.error = Sanitizer.clean(error.localizedDescription) }
                    }
                }
            }
    }
}

// MARK: - HomeView (единый блок подписки + кнопка + таймер)

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var settings: AppSettings
    var onPickServer: () -> Void

    @State private var showAdd = false
    @State private var showScan = false
    @State private var now = Date()
    @State private var collapsed: Set<UUID> = []

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var connected: Bool { vpn.status == .connected }
    private var pulsing: Bool { vpn.status == .connected }

    private var statusText: String {
        switch vpn.status {
        case .connected: return "Подключено"
        case .connecting: return "Подключение…"
        case .reasserting: return "Переподключение…"
        case .disconnecting: return "Отключение…"
        default: return vpn.error == nil ? "Не подключено" : "Ошибка подключения"
        }
    }

    private var uptimeText: String? {
        guard let start = vpn.connectedAt, vpn.status == .connected else { return nil }
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Logo()

                VStack(spacing: 12) {
                    Button {
                        vpn.toggle(server: store.selected)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.accent.opacity(connected ? 0.35 : 0.12))
                                .frame(width: 240, height: 240)
                                .blur(radius: 40)

                            PulseRing(trigger: pulsing)

                            Circle()
                                .stroke(Theme.accentLight.opacity(0.35), lineWidth: 1)
                                .frame(width: 200, height: 200)
                            Circle()
                                .fill(connected
                                      ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentDark],
                                                                     startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Theme.card))
                                .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                                .frame(width: 170, height: 170)
                            Image(systemName: "power")
                                .font(.system(size: 62, weight: .semibold))
                                .foregroundColor(connected ? .white : Theme.accentLight)
                        }
                    }
                    .buttonStyle(.plain)

                    Text(statusText)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .legible()

                    if let up = uptimeText {
                        Text(up)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.accentLight)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.accent.opacity(0.15)))
                            .legible()
                    }

                    if let err = vpn.error {
                        Text(err)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: 0xFF8A8A))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

                HStack(spacing: 10) {
                    Text("МОИ ПОДПИСКИ")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(0.8)
                        .foregroundColor(Theme.muted)
                        .padding(.leading, 4)
                    Spacer()
                    Button { Task { await store.refreshAll() } } label: {
                        IconCircle(systemName: "arrow.clockwise", busy: !store.refreshing.isEmpty)
                    }.buttonStyle(.plain)
                    Button { showScan = true } label: {
                        IconCircle(systemName: "qrcode.viewfinder")
                    }.buttonStyle(.plain)
                    Button { showAdd = true } label: {
                        IconCircle(systemName: "plus")
                    }.buttonStyle(.plain)
                }

                if store.groups.isEmpty {
                    Text("Пока нет подписок. Нажмите «+», чтобы добавить, или отсканируйте QR-код.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.muted)
                        .padding(.top, 8)
                }

                ForEach(store.groups) { g in
                    SubscriptionBlock(group: g,
                                      collapsed: Binding(
                                        get: { collapsed.contains(g.id) },
                                        set: { v in
                                            if v { collapsed.insert(g.id) }
                                            else { collapsed.remove(g.id) }
                                        }
                                      ))
                }

                Button("Управление подписками") { onPickServer() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .onReceive(ticker) { t in now = t }
        .sheet(isPresented: $showAdd) { AddSheet().environmentObject(store) }
        .fullScreenCover(isPresented: $showScan) { ScanSheet().environmentObject(store) }
    }
}

// MARK: - Единый блок подписки с треугольником

struct SubscriptionBlock: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var vpn: VPNController
    let group: SubGroup
    @Binding var collapsed: Bool

    @State private var showSettings = false

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }

    private var subtitle: String {
        let count = "\(group.servers.count) серв."
        if group.url.isEmpty { return "\(count) · вручную" }
        guard let d = group.updatedAt else { return "\(count) · не обновлялась" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "ru_RU")
        return "\(count) · \(f.localizedString(for: d, relativeTo: Date()))"
    }

    private var trafficText: String? {
        var parts: [String] = []
        if let t = group.total { parts.append("\(fmt(group.used ?? 0)) / \(fmt(t))") }
        else if let u = group.used { parts.append("исп. \(fmt(u))") }
        if let e = group.expire {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateStyle = .short
            parts.append(e < Date() ? "истекла \(f.string(from: e))" : "до \(f.string(from: e))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var trafficFraction: Double? {
        guard let t = group.total, t > 0 else { return nil }
        return min(1, Double(group.used ?? 0) / Double(t))
    }

    private var serversSorted: [Server] {
        guard settings.sortByPing else { return group.servers }
        func key(_ p: Int?) -> Int {
            guard let p = p else { return Int.max - 1 }
            return p < 0 ? Int.max : p
        }
        return group.servers.sorted { key(store.pings[$0.id]) < key(store.pings[$1.id]) }
    }

    private var effectivePingDisplay: PingDisplay {
        group.pingDisplayOverride ?? settings.pingDisplay
    }

    private func pick(_ s: Server) {
        let changed = store.selected?.id != s.id
        store.selectedID = s.id
        if changed && vpn.isActive { vpn.switchServer(s) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
                } label: {
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                Button { showSettings = true } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { Task { await store.pingAll(group.id) } } label: {
                    IconCircle(systemName: "bolt.fill", busy: store.pingingGroups.contains(group.id))
                }.buttonStyle(.plain)

                if !group.url.isEmpty {
                    Button { Task { await store.refresh(group.id) } } label: {
                        IconCircle(systemName: "arrow.clockwise", busy: store.refreshing.contains(group.id))
                    }.buttonStyle(.plain)
                }

                Menu {
                    Button { showSettings = true } label: {
                        Label("Настройки подписки", systemImage: "gearshape")
                    }
                    Button { Task { await store.refresh(group.id) } } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.removeGroup(group.id)
                    } label: {
                        Label("Удалить подписку", systemImage: "trash")
                    }
                } label: {
                    IconCircle(systemName: "ellipsis")
                }
            }
            .padding(14)

            if let info = trafficText {
                Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    if let f = trafficFraction {
                        ProgressView(value: f)
                            .tint(f > 0.9 ? Color(hex: 0xFB923C) : Theme.accent)
                    }
                    Text(info)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.muted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if !collapsed && !serversSorted.isEmpty {
                Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
                ForEach(Array(serversSorted.enumerated()), id: \.element.id) { idx, s in
                    Button { pick(s) } label: {
                        CompactServerRow(server: s,
                                         selected: store.selected?.id == s.id,
                                         ping: store.pings[s.id],
                                         display: effectivePingDisplay)
                    }
                    .buttonStyle(.plain)
                    .serverActions(s)

                    if idx < serversSorted.count - 1 {
                        Rectangle().fill(Theme.border.opacity(0.3))
                            .frame(height: 1)
                            .padding(.leading, 14)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.glass))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: 1))
        .sheet(isPresented: $showSettings) {
            SubscriptionSettingsSheet(group: group)
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}

struct CompactServerRow: View {
    let server: Server
    let selected: Bool
    let ping: Int?
    let display: PingDisplay

    private var pingColor: Color {
        guard let p = ping else { return Theme.muted }
        if p < 0 { return Color(hex: 0xFF8A8A) }
        if p < 150 { return Color(hex: 0x4ADE80) }
        if p < 400 { return Color(hex: 0xFACC15) }
        return Color(hex: 0xFB923C)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(selected ? Theme.accent : Theme.accent.opacity(0.15))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(selected ? Theme.text : Theme.text.opacity(0.92))
                    .lineLimit(1)
                Text(server.protocolLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accentLight)
            }
            Spacer(minLength: 8)
            pingView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var pingView: some View {
        if let p = ping, p >= 0 {
            switch display {
            case .time:
                Text("\(p) мс")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(pingColor)
            case .dots:
                HStack(spacing: 3) {
                    ForEach(0..<4) { i in
                        Circle()
                            .fill(dotColor(for: i, ms: p))
                            .frame(width: 6, height: 6)
                    }
                }
            case .bar:
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border).frame(width: 46, height: 5)
                    Capsule().fill(pingColor)
                        .frame(width: max(6, 46 * barFraction(p)), height: 5)
                }
            }
        } else if ping != nil {
            Text("×").font(.system(size: 12, weight: .bold)).foregroundColor(Color(hex: 0xFF8A8A))
        } else {
            Text("—").font(.system(size: 12)).foregroundColor(Theme.muted.opacity(0.5))
        }
    }

    private func dotColor(for index: Int, ms: Int) -> Color {
        let thresholds = [80, 150, 300, 600]
        return ms <= thresholds[index] ? pingColor : Theme.border
    }
    private func barFraction(_ ms: Int) -> Double {
        max(0.1, min(1.0, 1.0 - Double(ms) / 800.0))
    }
}
// MARK: - Действия над конфигом (долгое нажатие)
// Пинг, QR-код, JSON инбаунда, переименовать, просмотр, редактирование

struct DetailedConfig {
    var name = ""
    var host = ""
    var port = 0
    var uuid = ""
    var password = ""
    var flow = ""
    var encryption = ""
    var security = ""
    var fingerprint = ""
    var sni = ""
    var alpn = ""
    var allowInsecure = false
    var publicKey = ""
    var shortId = ""
    var spiderX = ""
    var network = ""
    var serviceName = ""
    var authority = ""
    var path = ""
    var proto = ""
}

extension LinkParser {
    static func details(of server: Server) -> DetailedConfig {
        var d = DetailedConfig()
        d.name = server.name
        d.host = server.host
        d.port = server.port
        d.proto = server.proto

        if server.proto == "vmess" {
            let payload = String(server.link.dropFirst("vmess://".count))
            if let json = decodeBase64(payload),
               let data = json.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                d.uuid = (o["id"] as? String) ?? ""
                d.security = ((o["tls"] as? String) ?? "none").lowercased()
                d.sni = (o["sni"] as? String) ?? ""
                d.alpn = (o["alpn"] as? String) ?? ""
                d.fingerprint = (o["fp"] as? String) ?? ""
                d.network = (o["net"] as? String) ?? "tcp"
                d.path = (o["path"] as? String) ?? ""
                d.serviceName = d.path
                d.authority = (o["host"] as? String) ?? ""
                if let scy = o["scy"] as? String, !scy.isEmpty { d.encryption = scy }
                return d
            }
        }

        let (body, _) = splitFragment(server.link)
        guard let sch = body.range(of: "://") else { return d }
        var rest = String(body[sch.upperBound...])
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            query = parseQuery(String(rest[rest.index(after: q)...]))
            rest = String(rest[..<q])
        }
        if let sl = rest.firstIndex(of: "/") { rest = String(rest[..<sl]) }

        if let at = rest.lastIndex(of: "@") {
            let ui = String(rest[..<at])
            let decoded = ui.removingPercentEncoding ?? ui
            if server.proto == "vless" { d.uuid = decoded } else { d.password = decoded }
        } else if server.proto == "ss" {
            if let dec = decodeBase64(rest), let c = dec.firstIndex(of: ":") {
                d.encryption = String(dec[..<c])
                d.password = String(dec[dec.index(after: c)...])
            }
        }

        d.flow = query["flow"] ?? ""
        d.encryption = query["encryption"] ?? d.encryption
        d.security = (query["security"] ?? "none").lowercased()
        d.fingerprint = query["fp"] ?? ""
        d.sni = query["sni"] ?? query["peer"] ?? ""
        d.alpn = query["alpn"] ?? ""
        d.allowInsecure = query["allowInsecure"] == "1" || (query["allowInsecure"]?.lowercased() == "true")
        d.publicKey = query["pbk"] ?? ""
        d.shortId = query["sid"] ?? ""
        d.spiderX = query["spx"] ?? ""
        d.network = query["type"] ?? "tcp"
        d.serviceName = query["serviceName"] ?? query["path"] ?? ""
        d.authority = query["host"] ?? ""
        d.path = query["path"] ?? ""

        if server.proto == "hysteria2" {
            d.password = server.hy2Auth ?? ""
            d.security = "tls"
            d.sni = server.hy2SNI ?? ""
            d.allowInsecure = server.hy2Insecure
            d.network = "hysteria2"
            d.fingerprint = server.hy2Obfs ?? ""
            d.path = server.hy2ObfsPassword ?? ""
        }
        if server.proto == "tuic" {
            d.uuid = server.tuicUUID ?? ""
            d.password = server.tuicPassword ?? ""
            d.security = "tls"
            d.sni = server.tuicSNI ?? ""
            d.alpn = server.tuicALPN ?? "h3"
            d.allowInsecure = server.tuicInsecure ?? false
            d.network = "tuic"
            d.fingerprint = server.tuicCongestion ?? ""   // congestion control
            d.path = server.tuicUDPMode ?? ""             // udp relay mode
        }
        return d
    }

    static func rebuildLink(_ d: DetailedConfig, original: Server) -> String {
        switch d.proto {
        case "vless", "trojan": return rebuildURLStyle(d)
        case "vmess": return rebuildVMess(d)
        case "ss": return rebuildSS(d)
        case "hysteria2": return rebuildHysteria2(d)
        case "tuic": return rebuildTUIC(d)
        default: return original.link
        }
    }

    private static func rebuildURLStyle(_ d: DetailedConfig) -> String {
        var comps = URLComponents()
        comps.scheme = d.proto
        comps.host = d.host
        comps.port = d.port

        var items: [URLQueryItem] = []
        if !d.flow.isEmpty { items.append(.init(name: "flow", value: d.flow)) }
        if !d.encryption.isEmpty, d.encryption != "none" {
            items.append(.init(name: "encryption", value: d.encryption))
        }
        if !d.security.isEmpty, d.security != "none" {
            items.append(.init(name: "security", value: d.security))
        }
        if !d.fingerprint.isEmpty { items.append(.init(name: "fp", value: d.fingerprint)) }
        if !d.sni.isEmpty { items.append(.init(name: "sni", value: d.sni)) }
        if !d.alpn.isEmpty { items.append(.init(name: "alpn", value: d.alpn)) }
        if d.allowInsecure { items.append(.init(name: "allowInsecure", value: "1")) }
        if !d.publicKey.isEmpty { items.append(.init(name: "pbk", value: d.publicKey)) }
        if !d.shortId.isEmpty { items.append(.init(name: "sid", value: d.shortId)) }
        if !d.spiderX.isEmpty { items.append(.init(name: "spx", value: d.spiderX)) }
        if !d.network.isEmpty, d.network != "tcp" {
            items.append(.init(name: "type", value: d.network))
        }
        if !d.serviceName.isEmpty { items.append(.init(name: "serviceName", value: d.serviceName)) }
        if !d.authority.isEmpty { items.append(.init(name: "host", value: d.authority)) }
        if !d.path.isEmpty { items.append(.init(name: "path", value: d.path)) }
        comps.queryItems = items.isEmpty ? nil : items

        let userInfo = d.proto == "vless" ? d.uuid : d.password
        let encoded = userInfo.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? userInfo
        let fragment = d.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        var result = "\(d.proto)://\(encoded)@\(comps.host ?? "")"
        if let p = comps.port { result += ":\(p)" }
        if let q = comps.percentEncodedQuery { result += "?\(q)" }
        if !fragment.isEmpty { result += "#\(fragment)" }
        return result
    }

    private static func rebuildVMess(_ d: DetailedConfig) -> String {
        var obj: [String: Any] = [
            "v": "2", "ps": d.name, "add": d.host, "port": "\(d.port)",
            "id": d.uuid,
            "net": d.network.isEmpty ? "tcp" : d.network,
            "type": "none", "host": d.authority, "path": d.path,
            "tls": d.security == "tls" ? "tls" : "",
            "sni": d.sni, "alpn": d.alpn, "fp": d.fingerprint
        ]
        if !d.encryption.isEmpty { obj["scy"] = d.encryption }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let json = String(data: data, encoding: .utf8),
              let b64 = json.data(using: .utf8)?.base64EncodedString() else { return "vmess://" }
        return "vmess://\(b64)"
    }

    private static func rebuildSS(_ d: DetailedConfig) -> String {
        let cred = "\(d.encryption):\(d.password)"
        guard let data = cred.data(using: .utf8) else { return "" }
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let fragment = d.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        return "ss://\(b64)@\(d.host):\(d.port)#\(fragment)"
    }

    private static func rebuildTUIC(_ d: DetailedConfig) -> String {
        func enc(_ v: String) -> String { v.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? v }
        var result = "tuic://\(enc(d.uuid)):\(enc(d.password))@\(d.host):\(d.port)"
        var items: [String] = []
        if !d.fingerprint.isEmpty { items.append("congestion_control=\(d.fingerprint)") }
        if !d.path.isEmpty { items.append("udp_relay_mode=\(d.path)") }
        if !d.alpn.isEmpty { items.append("alpn=\(d.alpn)") }
        if !d.sni.isEmpty { items.append("sni=\(d.sni)") }
        if d.allowInsecure { items.append("allow_insecure=1") }
        if !items.isEmpty { result += "?" + items.joined(separator: "&") }
        let fragment = d.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        if !fragment.isEmpty { result += "#\(fragment)" }
        return result
    }

    private static func rebuildHysteria2(_ d: DetailedConfig) -> String {
        var result = "hysteria2://"
        let auth = d.password.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? d.password
        if !auth.isEmpty { result += "\(auth)@" }
        result += "\(d.host):\(d.port)/"
        var items: [String] = []
        if !d.sni.isEmpty { items.append("sni=\(d.sni)") }
        if d.allowInsecure { items.append("insecure=1") }
        if !d.fingerprint.isEmpty { items.append("obfs=\(d.fingerprint)") }
        if !d.path.isEmpty { items.append("obfs-password=\(d.path)") }
        if !items.isEmpty { result += "?" + items.joined(separator: "&") }
        let fragment = d.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""
        if !fragment.isEmpty { result += "#\(fragment)" }
        return result
    }
}

struct ConfigEditorSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let server: Server

    @State private var d: DetailedConfig
    @State private var saved = false

    init(server: Server) {
        self.server = server
        _d = State(initialValue: LinkParser.details(of: server))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    block("Параметры", icon: "slider.horizontal.3") {
                        editable("Имя", text: $d.name)
                        readOnly("Протокол", server.protocolLabel)
                        editable("Адрес", text: $d.host)
                        editableInt("Порт", value: $d.port)
                        if !d.uuid.isEmpty || server.proto == "vless" { editable("UUID", text: $d.uuid) }
                        if server.proto == "trojan" || server.proto == "ss" || server.proto == "hysteria2" || server.proto == "tuic" {
                            editable("Пароль", text: $d.password)
                        }
                        if server.proto == "vless" { editable("Flow", text: $d.flow) }
                        if server.proto == "ss" || server.proto == "vmess" {
                            editable("Шифрование", text: $d.encryption)
                        }
                    }
                    block("TLS", icon: "lock.shield") {
                        editable("Безопасность", text: $d.security)
                        editable("Отпечаток", text: $d.fingerprint)
                        editable("SNI", text: $d.sni)
                        editable("ALPN (через запятую)", text: $d.alpn)
                        editable("Публичный ключ", text: $d.publicKey)
                        editable("Short ID", text: $d.shortId)
                        editable("SpiderX", text: $d.spiderX)
                        toggle("Разрешить небезопасные", isOn: $d.allowInsecure)
                    }
                    block("Сеть", icon: "network") {
                        editable("Сеть", text: $d.network)
                        editable("Имя сервиса", text: $d.serviceName)
                        editable("Authority", text: $d.authority)
                        editable("Path", text: $d.path)
                    }
                }
                .padding(24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Редактирование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(Theme.accentLight)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(saved ? "Сохранено" : "Сохранить") { saveChanges() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accentLight)
                        .disabled(saved)
                }
            }
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }

    private func saveChanges() {
        let newLink = LinkParser.rebuildLink(d, original: server)
        guard let newServer = LinkParser.parse(newLink) else { return }
        store.updateServer(server.id, with: newServer, newLink: newLink)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
    }

    @ViewBuilder
    private func block<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.accentLight)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.8)
                    .foregroundColor(Theme.muted)
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    private func editable(_ k: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.system(size: 12)).foregroundColor(Theme.muted)
            TextField("", text: text)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .foregroundColor(Theme.text)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func editableInt(_ k: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.system(size: 12)).foregroundColor(Theme.muted)
            TextField("", value: value, formatter: NumberFormatter())
                .keyboardType(.numberPad)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.text)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func readOnly(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 13)).foregroundColor(Theme.muted)
            Spacer()
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.text)
        }
    }

    private func toggle(_ k: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(k).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.text)
        }
        .tint(Theme.accent)
    }
}

struct ConfigDetailsSheet: View {
    let server: Server
    @Environment(\.dismiss) private var dismiss
    private var d: DetailedConfig { LinkParser.details(of: server) }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    block("Параметры", icon: "slider.horizontal.3") {
                        field("Имя конфига", d.name)
                        field("Протокол", server.protocolLabel)
                        field("Адрес", d.host)
                        field("Порт", "\(d.port)")
                        if !d.uuid.isEmpty { field("UUID", d.uuid) }
                        if !d.password.isEmpty { field("Пароль", d.password) }
                        if !d.flow.isEmpty { field("Flow", d.flow) }
                    }
                    block("TLS", icon: "lock.shield") {
                        if !d.encryption.isEmpty { field("Шифрование", d.encryption) }
                        field("Безопасность", d.security.isEmpty ? "none" : d.security)
                        if !d.fingerprint.isEmpty { field("Отпечаток", d.fingerprint) }
                        if !d.sni.isEmpty { field("SNI", d.sni) }
                        if !d.alpn.isEmpty { field("ALPN", d.alpn) }
                        if !d.publicKey.isEmpty { field("Публичный ключ", d.publicKey) }
                        if !d.shortId.isEmpty { field("Short ID", d.shortId) }
                        if !d.spiderX.isEmpty { field("SpiderX", d.spiderX) }
                        field("Разрешить небезопасные", d.allowInsecure ? "да" : "нет", bad: d.allowInsecure)
                    }
                    block("Сеть", icon: "network") {
                        field("Сеть", d.network.isEmpty ? "tcp" : d.network)
                        if !d.serviceName.isEmpty { field("Имя сервиса", d.serviceName) }
                        if !d.authority.isEmpty { field("Authority", d.authority) }
                    }
                }
                .padding(24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Просмотр конфига")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accentLight)
                }
            }
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }

    @ViewBuilder
    private func block<C: View>(_ title: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.accentLight)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.8)
                    .foregroundColor(Theme.muted)
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
    }

    private func field(_ k: String, _ v: String, bad: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 13)).foregroundColor(Theme.muted)
            Spacer(minLength: 12)
            Text(v.isEmpty ? "-" : v)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(bad ? Color(hex: 0xFF8A8A) : Theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct QRCodeSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    private var qrImage: UIImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 10
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Spacer()
                if let img = qrImage {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 280, height: 280)
                        .padding(20)
                        .background(RoundedRectangle(cornerRadius: 24).fill(.white))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 42))
                            .foregroundColor(Color(hex: 0xFB923C))
                        Text("Не удалось создать QR-код. Ссылка слишком длинная - скопируйте её вручную.")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.muted)
                    .lineLimit(4)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
                    .textSelection(.enabled)
                Spacer()
                Button("Скопировать ссылку") {
                    UIPasteboard.general.string = text
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("QR-код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accentLight)
                }
            }
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }
}

struct JSONInboundSheet: View {
    let server: Server
    @Environment(\.dismiss) private var dismiss

    private var json: String {
        do {
            let profile = try XrayConfigBuilder.build(for: server, options: TunnelOptions(), logPath: nil)
            guard let data = profile.json.data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outbounds = obj["outbounds"] as? [[String: Any]],
                  let first = outbounds.first else { return profile.json }
            let pretty = try JSONSerialization.data(withJSONObject: first,
                                                    options: [.prettyPrinted, .sortedKeys])
            return String(decoding: pretty, as: UTF8.self)
        } catch {
            return "// Ошибка: \(error.localizedDescription)"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                Text(json)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("JSON инбаунда")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Копировать") { UIPasteboard.general.string = json }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accentLight)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Готово") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accentLight)
                }
            }
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }
}

struct RenameSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let server: Server
    @State private var name: String

    init(server: Server) {
        self.server = server
        _name = State(initialValue: server.name)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Новое имя").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.muted)
                TextField("Имя конфига", text: $name)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .foregroundColor(Theme.text)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                Button("Сохранить") {
                    store.renameServer(server.id, to: name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            .padding(24)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Переименовать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(Theme.accentLight)
                }
            }
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }
}

private struct ServerActionsModifier: ViewModifier {
    @EnvironmentObject var store: Store
    let server: Server

    @State private var detail = false
    @State private var edit = false
    @State private var qr = false
    @State private var json = false
    @State private var rename = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { Task { await store.pingSingle(server) } } label: {
                    Label("Пинг", systemImage: "bolt.fill")
                }
                Button { edit = true } label: {
                    Label("Редактировать", systemImage: "pencil.tip.crop.circle")
                }
                Button { qr = true } label: {
                    Label("QR-код", systemImage: "qrcode")
                }
                Button { json = true } label: {
                    Label("JSON инбаунда", systemImage: "curlybraces")
                }
                Button { rename = true } label: {
                    Label("Переименовать", systemImage: "pencil")
                }
                Button { detail = true } label: {
                    Label("Просмотр конфига", systemImage: "doc.text.magnifyingglass")
                }
                Divider()
                Button(role: .destructive) {
                    store.removeServer(server.id)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
            .sheet(isPresented: $detail) { ConfigDetailsSheet(server: server) }
            .sheet(isPresented: $edit) {
                ConfigEditorSheet(server: server).environmentObject(store)
            }
            .sheet(isPresented: $qr) { QRCodeSheet(text: server.link) }
            .sheet(isPresented: $json) { JSONInboundSheet(server: server) }
            .sheet(isPresented: $rename) { RenameSheet(server: server) }
    }
}

extension View {
    func serverActions(_ server: Server) -> some View {
        modifier(ServerActionsModifier(server: server))
    }
}

// MARK: - Настройки подписки

struct SubscriptionSettingsSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let group: SubGroup

    @State private var name: String
    @State private var url: String
    @State private var updateEnabled: Bool
    @State private var updateHours: Int
    @State private var pingDisplay: PingDisplay
    @State private var pingProtocol: PingProtocol
    @State private var tunnelDNS: String

    init(group: SubGroup) {
        self.group = group
        _name = State(initialValue: group.name)
        _url = State(initialValue: group.url)
        _updateEnabled = State(initialValue: group.updateIntervalHours != nil)
        _updateHours = State(initialValue: group.updateIntervalHours ?? 12)
        _pingDisplay = State(initialValue: group.pingDisplayOverride ?? .time)
        _pingProtocol = State(initialValue: group.pingProtocolOverride ?? .tcp)
        _tunnelDNS = State(initialValue: (group.tunnelDNS ?? []).joined(separator: ", "))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Основное", icon: "info.circle") {
                        field("Название", text: $name)
                        if !group.url.isEmpty { field("URL подписки", text: $url) }
                    }
                    section("Обновление", icon: "arrow.clockwise",
                            footer: "Если выключено, используется глобальный интервал из настроек.") {
                        ToggleRow(title: "Свой интервал",
                                  subtitle: "Переопределить глобальный",
                                  isOn: $updateEnabled)
                        if updateEnabled {
                            MenuRow(title: "Интервал", selection: $updateHours,
                                    options: [(1, "1 ч"), (3, "3 ч"), (6, "6 ч"), (12, "12 ч"),
                                              (24, "24 ч"), (48, "48 ч"), (168, "7 дней")])
                        }
                    }
                    section("Пинг", icon: "bolt.fill",
                            footer: "Применяется только к этой подписке.") {
                        MenuRow(title: "Отображение", selection: $pingDisplay,
                                options: [(PingDisplay.time, "Время"),
                                          (PingDisplay.dots, "Точки"),
                                          (PingDisplay.bar, "Шкала")])
                        MenuRow(title: "Протокол", selection: $pingProtocol,
                                options: PingProtocol.allCases.map { ($0, $0.title) })
                        Text(pingProtocol.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.muted)
                    }
                    section("DNS туннеля", icon: "globe",
                            footer: "Свои DNS-серверы для этой подписки. Через запятую. Пусто - глобальные.") {
                        field("DNS через запятую", text: $tunnelDNS)
                    }
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Настройки подписки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(Theme.accentLight)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Сохранить") { save() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accentLight)
                }
            }
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }

    private func save() {
        let dnsList = tunnelDNS
            .components(separatedBy: CharacterSet(charactersIn: ", \n;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.updateGroupSettings(
            group.id,
            name: name.trimmingCharacters(in: .whitespaces),
            url: url.trimmingCharacters(in: .whitespaces),
            updateIntervalHours: updateEnabled ? updateHours : nil,
            pingDisplay: pingDisplay,
            pingProtocol: pingProtocol,
            tunnelDNS: dnsList.isEmpty ? nil : dnsList
        )
        dismiss()
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, icon: String, footer: String? = nil,
                                   @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.accentLight)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.8)
                    .foregroundColor(Theme.muted)
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            if let f = footer {
                Text(f).font(.system(size: 12)).foregroundColor(Theme.muted).padding(.horizontal, 4)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundColor(Theme.muted)
            TextField("", text: text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .foregroundColor(Theme.text)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
        }
    }
}
// MARK: - KeychainStore

enum KeychainStore {
    private static let service = "com.eclipse.client"

    @discardableResult
    static func save(_ data: Data, forKey key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

// MARK: - AppSettings

enum DNSPreset: String, CaseIterable, Identifiable {
    case cloudflare, google, quad9, adguard, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .adguard: return "AdGuard (без рекламы)"
        case .custom: return "Свой"
        }
    }
    var servers: [String] {
        switch self {
        case .cloudflare, .custom: return ["1.1.1.1", "1.0.0.1"]
        case .google: return ["8.8.8.8", "8.8.4.4"]
        case .quad9: return ["9.9.9.9", "149.112.112.112"]
        case .adguard: return ["94.140.14.14", "94.140.15.15"]
        }
    }
}

enum UAPreset: String, CaseIterable, Identifiable {
    case eclipse, happ, v2rayn, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .eclipse: return "Eclipse"
        case .happ: return "Happ"
        case .v2rayn: return "v2rayN"
        case .custom: return "Свой"
        }
    }
    var value: String {
        switch self {
        case .eclipse, .custom: return "Eclipse/1.3"
        case .happ: return "Happ/3.0.0"
        case .v2rayn: return "v2rayN/7.0"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private static let keyPrefix = "eclipse.s."

    @Published var onDemand: Bool { didSet { save(onDemand, "onDemand") } }
    @Published var mtu: Int { didSet { save(mtu, "mtu") } }
    @Published var dnsPreset: DNSPreset { didSet { save(dnsPreset.rawValue, "dnsPreset") } }
    @Published var customDNS: String { didSet { save(customDNS, "customDNS") } }
    @Published var bypassLAN: Bool { didSet { save(bypassLAN, "bypassLAN") } }
    @Published var directRules: String { didSet { save(directRules, "directRules") } }
    @Published var useGeoRouting: Bool { didSet { save(useGeoRouting, "useGeoRouting") } }
    @Published var geoipDirect: String { didSet { save(geoipDirect, "geoipDirect") } }
    @Published var geositeDirect: String { didSet { save(geositeDirect, "geositeDirect") } }
    @Published var sniffing: Bool { didSet { save(sniffing, "sniffing") } }
    @Published var mux: Bool { didSet { save(mux, "mux") } }
    @Published var fragment: Bool { didSet { save(fragment, "fragment") } }
    @Published var memoryLimit: Int { didSet { save(memoryLimit, "memoryLimit") } }
    @Published var autoUpdate: Bool { didSet { save(autoUpdate, "autoUpdate") } }
    @Published var updateHours: Int { didSet { save(updateHours, "updateHours") } }
    @Published var requestTimeout: Int { didSet { save(requestTimeout, "requestTimeout") } }
    @Published var uaPreset: UAPreset { didSet { save(uaPreset.rawValue, "uaPreset") } }
    @Published var customUA: String { didSet { save(customUA, "customUA") } }
    @Published var sendHWID: Bool { didSet { save(sendHWID, "sendHWID") } }
    @Published var sortByPing: Bool { didSet { save(sortByPing, "sortByPing") } }
    @Published var pingDisplay: PingDisplay { didSet { save(pingDisplay.rawValue, "pingDisplay") } }
    @Published var pingProtocol: PingProtocol { didSet { save(pingProtocol.rawValue, "pingProtocol") } }
    @Published var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }

    private func save(_ v: Any, _ key: String) {
        UserDefaults.standard.set(v, forKey: Self.keyPrefix + key)
    }

    private init() {
        let d = UserDefaults.standard
        let p = AppSettings.keyPrefix
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: p + k) as? Bool ?? def }
        func i(_ k: String, _ def: Int) -> Int { d.object(forKey: p + k) as? Int ?? def }
        func s(_ k: String, _ def: String) -> String { d.string(forKey: p + k) ?? def }
        onDemand = b("onDemand", false)
        mtu = i("mtu", 1400)
        dnsPreset = DNSPreset(rawValue: s("dnsPreset", "cloudflare")) ?? .cloudflare
        customDNS = s("customDNS", "")
        bypassLAN = b("bypassLAN", true)
        directRules = s("directRules", "")
        useGeoRouting = b("useGeoRouting", false)
        geoipDirect = s("geoipDirect", "ru")
        geositeDirect = s("geositeDirect", "category-ads-all")
        sniffing = b("sniffing", true)
        mux = b("mux", false)
        fragment = b("fragment", false)
        memoryLimit = i("memoryLimit", 50)
        autoUpdate = b("autoUpdate", true)
        updateHours = i("updateHours", 12)
        requestTimeout = i("requestTimeout", 20)
        uaPreset = UAPreset(rawValue: s("uaPreset", "eclipse")) ?? .eclipse
        customUA = s("customUA", "")
        sendHWID = b("sendHWID", false)
        sortByPing = b("sortByPing", false)
        pingDisplay = PingDisplay(rawValue: s("pingDisplay", "time")) ?? .time
        pingProtocol = PingProtocol(rawValue: s("pingProtocol", "tcp")) ?? .tcp
        appearance = AppearanceMode(rawValue: s("appearance", "dark")) ?? .dark
    }

    func reset() {
        onDemand = false; mtu = 1400
        dnsPreset = .cloudflare; customDNS = ""
        bypassLAN = true; directRules = ""
        useGeoRouting = false; geoipDirect = "ru"; geositeDirect = "category-ads-all"
        sniffing = true; mux = false; fragment = false
        memoryLimit = 50
        autoUpdate = true; updateHours = 12; requestTimeout = 20
        uaPreset = .eclipse; customUA = ""; sendHWID = false; sortByPing = false
        pingDisplay = .time; pingProtocol = .tcp
        appearance = .dark
    }

    static func isIP(_ s: String) -> Bool {
        var a = in_addr(), b = in6_addr()
        return inet_pton(AF_INET, s, &a) == 1 || inet_pton(AF_INET6, s, &b) == 1
    }

    var resolvedDNS: [String] {
        guard dnsPreset == .custom else { return dnsPreset.servers }
        let items = customDNS
            .components(separatedBy: CharacterSet(charactersIn: ", \n;"))
            .filter { !$0.isEmpty && AppSettings.isIP($0) }
        return items.isEmpty ? DNSPreset.cloudflare.servers : items
    }

    var tunnelOptions: TunnelOptions {
        var o = TunnelOptions()
        o.mtu = mtu
        o.dns = resolvedDNS
        o.mux = mux
        o.fragment = fragment
        o.sniffing = sniffing
        o.bypassLAN = bypassLAN
        o.memoryLimit = memoryLimit
        var rules = directRules
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if useGeoRouting {
            let ipRules = geoipDirect
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "geoip:\($0)" }
            let siteRules = geositeDirect
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { "geosite:\($0)" }
            rules.append(contentsOf: ipRules)
            rules.append(contentsOf: siteRules)
        }
        o.directRules = rules
        return o
    }

    var userAgent: String {
        if uaPreset == .custom {
            let t = customUA.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? UAPreset.eclipse.value : t
        }
        return uaPreset.value
    }

    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    func apply(to req: inout URLRequest) {
        req.timeoutInterval = TimeInterval(requestTimeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if sendHWID {
            let dev = UIDevice.current
            req.setValue(dev.identifierForVendor?.uuidString ?? "", forHTTPHeaderField: "x-hwid")
            req.setValue("iOS", forHTTPHeaderField: "x-device-os")
            req.setValue(dev.systemVersion, forHTTPHeaderField: "x-ver-os")
            req.setValue(AppSettings.modelIdentifier, forHTTPHeaderField: "x-device-model")
        }
    }
}

// MARK: - Общие компоненты настроек

struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let footer: String?
    let content: Content

    init(_ title: String, icon: String = "circle", footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.accentLight)
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.8)
                    .foregroundColor(Theme.muted)
            }
            .padding(.leading, 4)
            .legible()
            VStack(alignment: .leading, spacing: 14) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            if let f = footer {
                Text(f)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .padding(.horizontal, 4)
                    .legible()
            }
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.text)
                if let s = subtitle {
                    Text(s).font(.system(size: 12)).foregroundColor(Theme.muted)
                }
            }
        }
        .tint(Theme.accent)
        .disabled(disabled)
    }
}

struct MenuRow<T: Hashable>: View {
    let title: String
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(Theme.text)
            Spacer()
            Menu {
                ForEach(options.indices, id: \.self) { i in
                    Button(options[i].1) { selection = options[i].0 }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(options.first(where: { $0.0 == selection })?.1 ?? "-")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.accentLight)
            }
        }
    }
}

struct SettingsField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .foregroundColor(Theme.text)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}

// MARK: - SettingsView (категории с иконками)

struct SettingsCategoryRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let destination: AnyView

    init(title: String, subtitle: String, icon: String, color: Color = Theme.accent,
         @ViewBuilder destination: () -> some View) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
        self.destination = AnyView(destination())
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(color)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.muted).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.muted.opacity(0.6))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.glass))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.15))
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.accentLight)
                    }
                    .frame(width: 36, height: 36)
                    Text(title).font(.system(size: 24, weight: .bold)).foregroundColor(Theme.text).legible()
                }
                .padding(.bottom, 4)
                content
            }
            .padding(20)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var settings: AppSettings
    @State private var log = ""
    @State private var copied = false
    @State private var confirmReset = false
    @State private var confirmProfiles = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.3"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "4"
        return "\(v) (\(b))"
    }
    private var statusName: String {
        switch vpn.status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Logo()
                    Text("Настройки")
                        .font(.system(size: 34, weight: .bold))
                        .kerning(-1)
                        .foregroundColor(Theme.text)
                        .legible()
                        .padding(.bottom, 8)

                    SectionHeader("Оформление")
                    SettingsCategoryRow(title: "Тема",
                                        subtitle: settings.appearance.title,
                                        icon: "circle.lefthalf.filled", color: Color(hex: 0xA07CFF)) {
                        SettingsPage("Тема", icon: "circle.lefthalf.filled") {
                            SettingsSection("Оформление", icon: "paintpalette") {
                                MenuRow(title: "Тема приложения", selection: $settings.appearance,
                                        options: AppearanceMode.allCases.map { ($0, $0.title) })
                            }
                        }
                        .environmentObject(settings)
                    }

                    SectionHeader("Соединение")
                    SettingsCategoryRow(title: "Соединение",
                                        subtitle: "Kill-switch, автоподключение, MTU",
                                        icon: "antenna.radiowaves.left.and.right") {
                        SettingsPage("Соединение", icon: "antenna.radiowaves.left.and.right") {
                            SettingsSection("Безопасность", icon: "lock.shield",
                                            footer: "Kill-switch блокирует интернет, если туннель упадёт. Пока VPN активен - изменить нельзя.") {
                                ToggleRow(title: "Блокировать трафик при обрыве",
                                          subtitle: "Kill-switch",
                                          isOn: $vpn.killSwitch, disabled: vpn.isActive)
                                ToggleRow(title: "Автоподключение",
                                          subtitle: "iOS сама включит VPN, когда появится сеть",
                                          isOn: $settings.onDemand)
                            }
                            SettingsSection("Параметры", icon: "slider.horizontal.3") {
                                MenuRow(title: "MTU", selection: $settings.mtu,
                                        options: [(1280, "1280"), (1400, "1400"), (1500, "1500")])
                            }
                        }
                        .environmentObject(vpn).environmentObject(settings)
                    }

                    SettingsCategoryRow(title: "DNS",
                                        subtitle: settings.dnsPreset.title,
                                        icon: "globe", color: Color(hex: 0x4ADE80)) {
                        SettingsPage("DNS", icon: "globe") {
                            SettingsSection("Сервер", icon: "server.rack",
                                            footer: "DNS применяется системно и внутри ядра. Для своего DNS укажите IP через запятую.") {
                                MenuRow(title: "Сервер", selection: $settings.dnsPreset,
                                        options: DNSPreset.allCases.map { ($0, $0.title) })
                                if settings.dnsPreset == .custom {
                                    SettingsField(placeholder: "1.1.1.1, 8.8.8.8", text: $settings.customDNS)
                                }
                            }
                        }
                        .environmentObject(settings)
                    }

                    SectionHeader("Туннель")

                    SettingsCategoryRow(title: "Маршрутизация",
                                        subtitle: "Домены, IP, подсети напрямую",
                                        icon: "arrow.triangle.branch", color: Color(hex: 0xFB923C)) {
                        SettingsPage("Маршрутизация", icon: "arrow.triangle.branch") {
                            SettingsSection("Локальные сети", icon: "house") {
                                ToggleRow(title: "Напрямую",
                                          subtitle: "10.x, 172.16.x, 192.168.x - без VPN",
                                          isOn: $settings.bypassLAN)
                            }
                            SettingsSection("Правила", icon: "list.bullet",
                                            footer: "По одному в строке: домен (example.com), IP или подсеть (10.0.0.0/8). Идут напрямую. Для доменов нужен sniffing.") {
                                ZStack(alignment: .topLeading) {
                                    if settings.directRules.isEmpty {
                                        Text("example.com\n192.168.1.0/24")
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(Theme.muted.opacity(0.6))
                                            .padding(.top, 8).padding(.leading, 5)
                                    }
                                    TextEditor(text: $settings.directRules)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(Theme.text)
                                        .textInputAutocapitalization(.never)
                                        .disableAutocorrection(true)
                                        .frame(minHeight: 120)
                                }
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                            }
                        }
                        .environmentObject(settings)
                    }

                    SettingsCategoryRow(title: "Маршрутизация (Geo)",
                                        subtitle: settings.useGeoRouting ? "включено" : "выключено",
                                        icon: "map", color: Color(hex: 0xFACC15)) {
                        SettingsPage("GeoIP / GeoSite", icon: "map") {
                            SettingsSection("Обход по базам", icon: "globe.asia.australia",
                                            footer: "Базы GeoIP/GeoSite скачиваются автоматически при первой загрузке подписки.") {
                                ToggleRow(title: "Использовать GeoIP/GeoSite",
                                          subtitle: "Направлять трафик напрямую по базам",
                                          isOn: $settings.useGeoRouting)
                                if settings.useGeoRouting {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("GeoIP напрямую").font(.system(size: 12)).foregroundColor(Theme.muted)
                                        SettingsField(placeholder: "ru, cn", text: $settings.geoipDirect)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("GeoSite напрямую").font(.system(size: 12)).foregroundColor(Theme.muted)
                                        SettingsField(placeholder: "category-ads-all, private", text: $settings.geositeDirect)
                                    }
                                }
                            }
                        }
                        .environmentObject(settings)
                    }

                    SettingsCategoryRow(title: "Ядро",
                                        subtitle: "Sniffing, Mux, фрагментация TLS",
                                        icon: "cpu", color: Color(hex: 0xA07CFF)) {
                        SettingsPage("Ядро", icon: "cpu") {
                            SettingsSection("Sniffing и Mux", icon: "waveform",
                                            footer: "Mux и фрагментация увеличивают расход памяти. Включайте по необходимости.") {
                                ToggleRow(title: "Определять трафик (sniffing)",
                                          subtitle: "Нужен для правил по доменам",
                                          isOn: $settings.sniffing)
                                ToggleRow(title: "Мультиплексирование (Mux)",
                                          subtitle: "Несколько потоков в одном соединении",
                                          isOn: $settings.mux)
                                ToggleRow(title: "Фрагментация TLS",
                                          subtitle: "Помогает обходить DPI-блокировки",
                                          isOn: $settings.fragment)
                            }
                        }
                        .environmentObject(settings)
                    }

                    SettingsCategoryRow(title: "Производительность",
                                        subtitle: "Лимит памяти \(settings.memoryLimit) МБ",
                                        icon: "speedometer", color: Color(hex: 0xFB923C)) {
                        SettingsPage("Производительность", icon: "speedometer") {
                            SettingsSection("Память ядра", icon: "memorychip",
                                            footer: "Ограничение памяти Xray. Маленькое значение - сбои, большое - расход батареи.") {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Лимит").font(.system(size: 15, weight: .medium)).foregroundColor(Theme.text)
                                        Spacer()
                                        Text("\(settings.memoryLimit) МБ")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(Theme.accentLight)
                                    }
                                    Slider(value: Binding(
                                        get: { Double(settings.memoryLimit) },
                                        set: { settings.memoryLimit = Int($0) }
                                    ), in: 30...128, step: 5).tint(Theme.accent)
                                }
                            }
                        }
                        .environmentObject(settings)
                    }

                    SectionHeader("Провайдеры")

                    SettingsCategoryRow(title: "Подписки",
                                        subtitle: "Обновление, таймаут, UA, HWID",
                                        icon: "tray.full", color: Color(hex: 0x4ADE80)) {
                        SettingsPage("Подписки", icon: "tray.full") {
                            SettingsSection("Обновление", icon: "arrow.clockwise") {
                                ToggleRow(title: "Автообновление",
                                          subtitle: "При запуске приложения",
                                          isOn: $settings.autoUpdate)
                                if settings.autoUpdate {
                                    MenuRow(title: "Интервал", selection: $settings.updateHours,
                                            options: [(6, "6 ч"), (12, "12 ч"), (24, "24 ч"), (48, "48 ч")])
                                }
                            }
                            SettingsSection("Запросы", icon: "network",
                                            footer: "HWID передаёт уникальный ID устройства провайдеру. Включайте только если сервис требует.") {
                                MenuRow(title: "Таймаут", selection: $settings.requestTimeout,
                                        options: [(10, "10 с"), (20, "20 с"), (30, "30 с"), (60, "60 с")])
                                MenuRow(title: "User-Agent", selection: $settings.uaPreset,
                                        options: UAPreset.allCases.map { ($0, $0.title) })
                                if settings.uaPreset == .custom {
                                    SettingsField(placeholder: "Например, MyClient/1.3", text: $settings.customUA)
                                }
                                ToggleRow(title: "Отправлять HWID",
                                          subtitle: "x-hwid и данные об устройстве",
                                          isOn: $settings.sendHWID)
                                ToggleRow(title: "Сортировать серверы по пингу",
                                          subtitle: "Сначала самые быстрые",
                                          isOn: $settings.sortByPing)
                            }
                        }
                        .environmentObject(settings)
                    }

                    SettingsCategoryRow(title: "Настройки пинга",
                                        subtitle: "\(settings.pingDisplay.title) · \(settings.pingProtocol.title)",
                                        icon: "bolt.fill", color: Theme.accent) {
                        SettingsPage("Настройки пинга", icon: "bolt.fill") {
                            SettingsSection("Сортировка", icon: "arrow.up.arrow.down") {
                                ToggleRow(title: "Сортировать по пингу",
                                          subtitle: "Сначала самые быстрые",
                                          isOn: $settings.sortByPing)
                            }
                            SettingsSection("Отображение", icon: "eye",
                                            footer: "Способ показа пинга в списке серверов (по умолчанию).") {
                                MenuRow(title: "Режим", selection: $settings.pingDisplay,
                                        options: [(PingDisplay.time, "Время"),
                                                  (PingDisplay.dots, "Точки"),
                                                  (PingDisplay.bar, "Шкала")])
                            }
                            SettingsSection("Протокол", icon: "bolt.fill",
                                            footer: "TCP самый быстрый. HTTP GET/HEAD требуют больше ресурсов, ICMP может быть заблокирован.") {
                                MenuRow(title: "Протокол", selection: $settings.pingProtocol,
                                        options: PingProtocol.allCases.map { ($0, $0.title) })
                                Text(settings.pingProtocol.subtitle)
                                    .font(.system(size: 11)).foregroundColor(Theme.muted)
                            }
                        }
                        .environmentObject(settings)
                    }

                    SectionHeader("Диагностика")

                    SettingsCategoryRow(title: "Информация",
                                        subtitle: "Статус, расширение, App Group",
                                        icon: "stethoscope", color: Color(hex: 0xFB923C)) {
                        SettingsPage("Информация", icon: "stethoscope") {
                            SettingsSection("Состояние", icon: "info.circle") {
                                diagRow("iOS", UIDevice.current.systemVersion)
                                diagRow("Статус VPN", statusName)
                                diagRow("Приложение", Bundle.main.bundleIdentifier ?? "-")
                                diagRow("Расширение", vpn.embeddedExtensionID ?? "не найдено",
                                        bad: vpn.embeddedExtensionID == nil)
                                diagRow("App Group", AppGroup.available ? "доступна" : "недоступна",
                                        bad: !AppGroup.available)
                                diagRow("Geo-базы", GeoDat.available ? "есть" : "нет",
                                        bad: !GeoDat.available)
                                if let e = vpn.error { diagRow("Ошибка", e, bad: true) }
                            }
                            SettingsSection("Обслуживание", icon: "wrench.and.screwdriver",
                                            footer: "Удаление полезно, если iOS пишет «Не установлено приложение VPN».") {
                                Button("Удалить все VPN-профили") { confirmProfiles = true }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        .environmentObject(vpn)
                    }

                    SettingsCategoryRow(title: "Логи",
                                        subtitle: "Журнал работы приложения",
                                        icon: "doc.text.magnifyingglass") {
                        SettingsPage("Логи", icon: "doc.text.magnifyingglass") {
                            SettingsSection("Журнал", icon: "doc.text") {
                                HStack(spacing: 10) {
                                    Button { log = SharedLog.read() } label: {
                                        Label("Обновить", systemImage: "arrow.clockwise")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(Theme.text)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fg(0.06)))
                                    }.buttonStyle(.plain)

                                    Button {
                                        UIPasteboard.general.string = log
                                        copied = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                                    } label: {
                                        Label(copied ? "Готово" : "Копировать",
                                              systemImage: copied ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(Theme.text)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fg(0.06)))
                                    }.buttonStyle(.plain)

                                    Button {
                                        SharedLog.clear(); log = ""
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(Color(hex: 0xFF8A8A))
                                            .frame(width: 44)
                                            .padding(.vertical, 10)
                                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fg(0.06)))
                                    }.buttonStyle(.plain)
                                }
                                Text(log.isEmpty ? "Логи пусты" : log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(log.isEmpty ? Theme.muted : Theme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.field))
                            }
                        }
                    }

                    SectionHeader("Приложение")

                    SettingsCategoryRow(title: "О приложении",
                                        subtitle: "Eclipse \(version)",
                                        icon: "info.circle", color: Theme.accentLight) {
                        SettingsPage("О приложении", icon: "info.circle") {
                            SettingsSection("Информация", icon: "info.circle") {
                                diagRow("Eclipse", version)
                                diagRow("Ядро", "Xray-core")
                                diagRow("Туннель", "Tun2SocksKit")
                                diagRow("Лицензия", "GPL-3.0")
                            }
                            SettingsSection("Действия", icon: "gearshape") {
                                Button("Сбросить настройки") { confirmReset = true }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationBarHidden(true)
        }
        .onAppear { log = SharedLog.read() }
        .onChange(of: vpn.status) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { log = SharedLog.read() }
        }
        .confirmationDialog("Сбросить все настройки?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { settings.reset() }
        }
        .confirmationDialog("Удалить все VPN-профили Eclipse?",
                            isPresented: $confirmProfiles, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { vpn.removeAllProfiles() }
        }
    }

    private func diagRow(_ k: String, _ v: String, bad: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 13)).foregroundColor(Theme.muted)
            Spacer(minLength: 12)
            Text(v)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(bad ? Color(hex: 0xFF8A8A) : Theme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundColor(Theme.muted.opacity(0.85))
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.top, 8)
    }
}

// MARK: - ServersView (использует единый SubscriptionBlock)

struct ServersView: View {
    @EnvironmentObject var store: Store
    @State private var showAdd = false
    @State private var showScan = false
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Logo()
                HStack {
                    Text("Серверы")
                        .font(.system(size: 34, weight: .bold))
                        .kerning(-1)
                        .foregroundColor(Theme.text)
                        .legible()
                    Spacer()
                    Button { Task { await store.refreshAll() } } label: {
                        IconCircle(systemName: "arrow.clockwise", busy: !store.refreshing.isEmpty)
                    }.buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    Button("Добавить подписку") { showAdd = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { showScan = true } label: {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 22))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 64)
                }

                if let msg = store.message {
                    Text(msg).font(.system(size: 13)).foregroundColor(Color(hex: 0xFF8A8A))
                }

                if store.groups.isEmpty {
                    Text("Пока пусто. Добавьте ссылку подписки, отсканируйте QR-код или вставьте ссылку vless:// / vmess:// / trojan:// / ss:// / hysteria2:// / tuic://.")
                        .font(.system(size: 14)).foregroundColor(Theme.muted).padding(.top, 8)
                }

                ForEach(store.groups) { g in
                    SubscriptionBlock(group: g,
                                      collapsed: Binding(
                                        get: { collapsed.contains(g.id) },
                                        set: { v in
                                            if v { collapsed.insert(g.id) }
                                            else { collapsed.remove(g.id) }
                                        }
                                      ))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showAdd) { AddSheet().environmentObject(store) }
        .fullScreenCover(isPresented: $showScan) { ScanSheet().environmentObject(store) }
    }
}

// MARK: - Add / Scan sheets

struct AddSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Добавить").font(.system(size: 28, weight: .bold)).foregroundColor(Theme.text)
                Text("Ссылка подписки (https://…) или отдельная ссылка сервера (vless://, vmess://, trojan://, ss://, hysteria2://, tuic://)")
                    .font(.system(size: 14)).foregroundColor(Theme.muted)

                TextField("Вставьте ссылку", text: $text)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .foregroundColor(Theme.text).padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

                Button("Вставить из буфера") {
                    if let s = UIPasteboard.general.string { text = s }
                }.buttonStyle(SecondaryButtonStyle())

                Button {
                    busy = true
                    Task {
                        let ok = await store.add(text)
                        busy = false
                        if ok { dismiss() }
                    }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.white) }
                        Text(busy ? "Загрузка…" : "Добавить")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)

                if let msg = store.message {
                    Text(msg).font(.system(size: 13)).foregroundColor(Color(hex: 0xFF8A8A))
                }
                Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(AppSettings.shared.appearance.scheme)
    }
}

struct ScanSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var showPhoto = false
    @State private var status: String?
    @State private var busy = false

    private var hasCameraKey: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if hasCameraKey {
                QRScannerView(onCode: handle).ignoresSafeArea()
            } else {
                Text("Нет описания NSCameraUsageDescription в project.yml.")
                    .multilineTextAlignment(.center).foregroundColor(.white).padding(32)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white).padding(12)
                            .background(Circle().fill(Color.black.opacity(0.5)))
                    }
                }
                .padding()
                Spacer()
                if hasCameraKey {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Theme.accentLight, lineWidth: 3)
                        .frame(width: 240, height: 240)
                }
                Spacer()
                Text(status ?? "Наведите камеру на QR-код подписки")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white).multilineTextAlignment(.center).padding(.horizontal, 24)
                Button("Выбрать из фото") { showPhoto = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showPhoto) {
            PhotoQRPicker { code in
                showPhoto = false
                if let code = code { handle(code) } else { status = "QR-код не найден" }
            }
        }
    }

    private func handle(_ code: String) {
        guard !busy else { return }
        busy = true
        status = "Добавляем…"
        Task {
            let ok = await store.add(code)
            busy = false
            if ok { dismiss() } else { status = store.message ?? "Не удалось добавить" }
        }
    }
}

// MARK: - Scanner

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.onCode = onCode; return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var found = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.setup() } }
            }
        default: break
        }
    }
    private func setup() {
        guard let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let out = AVCaptureMetadataOutput()
        guard session.canAddOutput(out) else { return }
        session.addOutput(out)
        out.setMetadataObjectsDelegate(self, queue: .main)
        out.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); if session.isRunning { session.stopRunning() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !found,
              let o = objects.first as? AVMetadataMachineReadableCodeObject,
              let s = o.stringValue else { return }
        found = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCode?(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.found = false }
    }
}

struct PhotoQRPicker: UIViewControllerRepresentable {
    var onCode: (String?) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(); cfg.filter = .images; cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onCode: (String?) -> Void
        init(_ f: @escaping (String?) -> Void) { onCode = f }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let item = results.first?.itemProvider,
                  item.canLoadObject(ofClass: UIImage.self) else { onCode(nil); return }
            item.loadObject(ofClass: UIImage.self) { obj, _ in
                var code: String?
                if let img = obj as? UIImage, let ci = CIImage(image: img) {
                    let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                         options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
                    code = (det?.features(in: ci) as? [CIQRCodeFeature])?.first?.messageString
                }
                DispatchQueue.main.async { self.onCode(code) }
            }
        }
    }
}
