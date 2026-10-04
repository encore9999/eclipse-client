import SwiftUI
import NetworkExtension
import Foundation
import AVFoundation
import PhotosUI
import CoreImage

// Server, LinkParser, Pinger, AppGroup, TunnelKeys, SharedLog и XrayConfigBuilder
// лежат в папке Shared/ (компилируются и в приложение, и в расширение).
// GeoDat.swift также положи в папку Shared/ или в основную группу проекта.

// MARK: - EclipseApp.swift

@main
struct EclipseApp: App {
    @StateObject private var store = Store()
    @StateObject private var vpn = VPNController()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 13/255, green: 11/255, blue: 26/255, alpha: 1)
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
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var store: Store
    @State private var tab = 0

    var body: some View {
        // Фон рисуем внутри каждой вкладки: TabView в новых iOS закрашивает
        // свою область системным (чёрным) фоном и перекрывает фон снаружи.
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
    }
}

// MARK: - Theme.swift

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0D0B1A)
    static let bg2 = Color(hex: 0x140F28)
    static let card = Color(hex: 0x15121F)
    static let border = Color.white.opacity(0.09)
    static let accent = Color(hex: 0x7C5CFC)
    static let accentDark = Color(hex: 0x6040E0)
    static let accentLight = Color(hex: 0xC4ABFF)
    static let accent2 = Color(hex: 0xA07CFF)
    static let muted = Color(hex: 0x9B90CC)
}

// MARK: - Фон (как на сайте): свечение, волнистые линии, вращающиеся 3D-кубы

struct AppBackground: View {
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
            // затемнение: общий слой + «тёмное пятно» в центре, где основной текст
            Color.black.opacity(0.22)
            RadialGradient(colors: [Color.black.opacity(0.40), .clear],
                           center: .center, startRadius: 0, endRadius: 340)
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

// Скорость вращения кубов: медленно до подключения, разгон при подключении, затем плавное замедление.
// Значения — множители к скорости с сайта (1.0 = как на странице входа). Меняйте под вкус.
final class SceneMotion {
    static let shared = SceneMotion()
    static let idle = 0.25      // не подключено
    static let peak = 5.0       // пик сразу после подключения
    static let cruise = 0.7     // куда замедляется после разгона
    static let rampTime = 1.4   // сколько секунд держим разгон
    static let rampTau = 0.55   // как быстро разгоняемся
    static let settleTau = 3.5  // как плавно замедляемся
    static let idleTau = 1.5    // как плавно тормозим после отключения

    private var phase = 0.0     // накопленное «время вращения»
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
    // параметры взяты из страницы входа: 16 линий и 5 кубов
    private static let lines: [WaveLine] = {
        var r = SeededRNG(state: 20260404)
        return (0..<16).map { i in
            WaveLine(yFrac: Double(i) / 16, yJitter: r.next() * 15,
                     phase: r.next() * 2 * Double.pi,
                     speed: (0.0025 + r.next() * 0.004) * 60,     // рад/с (60 к/с в оригинале)
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

    // Куб: настоящее вращение в 3D + перспектива 900 (как perspective:900px в CSS)
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
        let count = size.width < 700 ? 3 : cubes.count      // как на сайте: на телефоне только 3 куба

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
            // дальние грани рисуем первыми
            let order = faces.sorted { a, b in
                a.map { pts[$0].1 }.reduce(0, +) < b.map { pts[$0].1 }.reduce(0, +)
            }
            ctx.drawLayer { layer in
                layer.addFilter(.shadow(color: Color(hex: 0x7C5CFC, opacity: 0.40),
                                        radius: 9, x: 0, y: 0))
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
            .foregroundColor(.white)
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
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: 0x0F0C20, opacity: 0.80)))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
    }
}

extension View {
    // лёгкая тень под текстом, который лежит прямо на анимированном фоне
    func legible() -> some View {
        shadow(color: .black.opacity(0.65), radius: 6, x: 0, y: 1)
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
            .foregroundColor(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct IconCircle: View {
    let systemName: String
    var busy: Bool = false
    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.18))
            if busy {
                ProgressView().tint(Theme.accentLight)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accentLight)
            }
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - Store.swift

// Подписка (группа серверов). url пустой у группы «Мои серверы» (одиночные ссылки).
struct SubGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var servers: [Server] = []
    var updatedAt: Date?
    // из заголовков подписки
    var used: Int64?
    var total: Int64?
    var expire: Date?
    var supportURL: String?
    var webURL: String?
}

final class Store: ObservableObject {
    @Published var groups: [SubGroup] = [] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }
    @Published var refreshing: Set<UUID> = []
    @Published var pingingGroups: Set<UUID> = []
    @Published var pings: [UUID: Int] = [:]   // мс, -1 = нет ответа
    @Published var message: String?

    private struct Saved: Codable {
        var groups: [SubGroup]
        var selectedID: UUID?
    }
    // формат прошлой версии, для переноса данных
    private struct OldSaved: Codable {
        var servers: [Server]
        var selectedID: UUID?
        var subscriptionURL: String
    }
    private let key = "eclipse.store.v2"
    private let oldKey = "encore.store.v1"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: key),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            groups = s.groups
            selectedID = s.selectedID
        } else if let data = d.data(forKey: oldKey),
                  let o = try? JSONDecoder().decode(OldSaved.self, from: data) {
            if !o.servers.isEmpty {
                let isSub = !o.subscriptionURL.isEmpty
                let name = isSub ? (URL(string: o.subscriptionURL)?.host ?? "Подписка") : "Мои серверы"
                groups = [SubGroup(name: name, url: o.subscriptionURL, servers: o.servers)]
            }
            selectedID = o.selectedID
        }
    }

    private func save() {
        let saved = Saved(groups: groups, selectedID: selectedID)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var allServers: [Server] { groups.flatMap { $0.servers } }

    var selected: Server? {
        allServers.first { $0.id == selectedID } ?? allServers.first
    }

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

    private func addManual(_ server: Server) {
        if let i = groups.firstIndex(where: { $0.url.isEmpty }) {
            groups[i].servers.append(server)
        } else {
            groups.append(SubGroup(name: "Мои серверы", url: "", servers: [server]))
        }
        selectedID = server.id
    }

    // Принимает ссылку подписки (в т.ч. из QR) или одиночную ссылку сервера
    @MainActor
    func add(_ input: String) async -> Bool {
        message = nil
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let single = LinkParser.parse(text) {
            addManual(single)
            return true
        }
        // обёртки вида happ://add/https%3A//... — достаём саму http(s)-ссылку
        let decoded = text.removingPercentEncoding ?? text
        for p in ["https://", "http://"] {
            if let r = decoded.range(of: p) {
                text = String(decoded[r.lowerBound...])
                break
            }
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
            if parsed.isEmpty {
                message = "В подписке не найдено серверов"
                return false
            }
            guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return false }
            let old = groups[i].servers
            // сохраняем id у прежних серверов, чтобы не терялись выбор и пинг
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
                groups[i].used = info.used
                groups[i].total = info.total
                groups[i].expire = info.expire
                groups[i].supportURL = http.value(forHTTPHeaderField: "support-url")
                groups[i].webURL = http.value(forHTTPHeaderField: "profile-web-page-url")
            }
            if let t = profileTitle(response) { groups[i].name = t }
            if !allServers.contains(where: { $0.id == selectedID }) {
                selectedID = allServers.first(where: { $0.link == selectedLink })?.id ?? allServers.first?.id
            }

            // === Скачивание гео-баз при первой успешной загрузке подписки ===
            if !GeoDat.available {
                Task.detached(priority: .utility) {
                    do {
                        try await GeoDat.download(
                            ip: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
                            site: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
                        )
                        SharedLog.write("[app] Гео-базы успешно скачаны")
                    } catch {
                        SharedLog.write("[app] Ошибка скачивания гео-баз: \(error.localizedDescription)")
                    }
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

    // "upload=0; download=123; total=1073741824; expire=1735689600"
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

    // Автообновление подписок при запуске (если включено в настройках)
    @MainActor
    func autoRefresh() async {
        let s = AppSettings.shared
        guard s.autoUpdate else { return }
        let limit = TimeInterval(s.updateHours) * 3600
        let ids = groups
            .filter { !$0.url.isEmpty && Date().timeIntervalSince($0.updatedAt ?? .distantPast) > limit }
            .map { $0.id }
        for id in ids { _ = await refresh(id) }
    }

    @MainActor
    func pingAll(_ groupID: UUID) async {
        guard let g = groups.first(where: { $0.id == groupID }), !g.servers.isEmpty else { return }
        pingingGroups.insert(groupID)
        let servers = g.servers
        await withTaskGroup(of: (UUID, Int).self) { group in
            for s in servers {
                group.addTask {
                    let ms = await Pinger.ping(host: s.host, port: s.port)
                    return (s.id, ms ?? -1)
                }
            }
            for await (id, ms) in group {
                await MainActor.run { self.pings[id] = ms }
            }
        }
        pingingGroups.remove(groupID)
    }
}

// MARK: - VPNController.swift

final class VPNController: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var error: String?
    @Published var killSwitch: Bool = UserDefaults.standard.bool(forKey: "killSwitch") {
        didSet { UserDefaults.standard.set(killSwitch, forKey: "killSwitch") }
    }
    private var manager: NETunnelProviderManager?
    private var previous: NEVPNStatus = .disconnected
    private var sawActive = false      // в этой сессии было подключение/попытка
    private var userStopped = false    // отключил сам пользователь
    private var pendingServer: Server?  // сервер, на который переключаемся

    init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, let conn = self.manager?.connection else { return }
            let new = conn.status
            SharedLog.write("[app] статус: \(new.rawValue)")
            self.previous = new
            self.status = new
            switch new {
            case .connecting, .connected, .reasserting: self.sawActive = true
            default: break
            }
            if new == .connected { self.error = nil }
            if new == .disconnected && self.sawActive {
                self.sawActive = false
                if !self.userStopped { self.collectError(conn) }
            }
            // смена сервера на лету: старый туннель остановился — поднимаем новый
            if new == .disconnected, let next = self.pendingServer {
                self.pendingServer = nil
                self.start(next)
            }
        }
    }

    // Ошибка, с которой остановилось расширение: сначала App Group, затем системная
    private func collectError(_ conn: NEVPNConnection) {
        let d = AppGroup.defaults
        if let msg = d.string(forKey: TunnelKeys.lastError) {
            d.removeObject(forKey: TunnelKeys.lastError)
            SharedLog.write("[app] ошибка из App Group: \(msg)")
            error = msg
            return
        }
        let fallback = "Туннель остановился без сообщения об ошибке. Вероятно, расширение упало при запуске. Подробности на вкладке «Настройки»."
        if #available(iOS 16.0, *) {
            conn.fetchLastDisconnectError { [weak self] err in
                DispatchQueue.main.async {
                    if let err = err as NSError? {
                        SharedLog.write("[app] fetchLastDisconnectError: \(err.domain) #\(err.code): \(err.localizedDescription)")
                        self?.error = err.localizedDescription
                    } else {
                        SharedLog.write("[app] fetchLastDisconnectError: nil")
                        self?.error = fallback
                    }
                }
            }
        } else {
            SharedLog.write("[app] iOS < 16: причина отключения недоступна")
            error = fallback
        }
    }

    // Реально встроенное расширение (если сервис подписи переименовал бандлы)
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
            }
        }
    }

    var isActive: Bool {
        switch status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    private func stopTunnel() {
        userStopped = true
        if let m = manager, m.isOnDemandEnabled {
            // иначе on-demand сразу поднимет туннель обратно
            m.isOnDemandEnabled = false
            m.saveToPreferences { _ in m.connection.stopVPNTunnel() }
        } else {
            manager?.connection.stopVPNTunnel()
        }
    }

    // Выбор другого сервера при активном подключении: перезапускаем туннель
    func switchServer(_ server: Server) {
        guard isActive else { return }
        SharedLog.write("[app] смена сервера → \(server.host):\(server.port)")
        pendingServer = server
        stopTunnel()
    }

    func toggle(server: Server?) {
        if isActive {
            SharedLog.write("[app] пользователь отключил VPN")
            pendingServer = nil
            stopTunnel()
            return
        }
        guard let server = server else {
            error = "Сначала добавьте сервер"
            return
        }
        start(server)
    }

    private func start(_ server: Server) {
        error = nil
        userStopped = false
        sawActive = false
        SharedLog.clear()
        SharedLog.write("[app] старт: \(server.protocolLabel) \(server.host):\(server.port)")
        // Конфиг строим в приложении: ошибки ссылки видны до старта туннеля.
        // logPath = nil: путь в песочнице приложения расширению недоступен.
        let profile: XrayProfile
        do {
            profile = try XrayConfigBuilder.build(for: server, options: AppSettings.shared.tunnelOptions, logPath: nil)
        } catch {
            SharedLog.write("[app] ошибка конфига: \(error.localizedDescription)")
            self.error = error.localizedDescription
            return
        }
        SharedLog.write("[app] конфиг Xray собран (\(profile.json.count) байт)")

        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            let m = managers?.first ?? NETunnelProviderManager()
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
                TunnelKeys.options: AppSettings.shared.tunnelOptions.json
            ]
            // Kill-switch средствами iOS: при падении туннеля трафик блокируется
            proto.includeAllNetworks = self.killSwitch
            proto.excludeLocalNetworks = true
            m.protocolConfiguration = proto
            m.localizedDescription = "Eclipse"
            m.isEnabled = true
            // Автоподключение: iOS сама поднимает туннель при появлении сети
            let onDemand = AppSettings.shared.onDemand
            m.isOnDemandEnabled = onDemand
            m.onDemandRules = onDemand ? [NEOnDemandRuleConnect() as NEOnDemandRule] : []
            m.saveToPreferences { saveError in
                if let saveError = saveError {
                    SharedLog.write("[app] saveToPreferences: \(saveError.localizedDescription)")
                    DispatchQueue.main.async {
                        self.error = "Не удалось сохранить VPN: \(saveError.localizedDescription)"
                    }
                    return
                }
                m.loadFromPreferences { _ in
                    DispatchQueue.main.async { self.manager = m }
                    do {
                        SharedLog.write("[app] startVPNTunnel, провайдер \(self.tunnelBundleID)")
                        try m.connection.startVPNTunnel()
                    } catch {
                        SharedLog.write("[app] startVPNTunnel error: \(error.localizedDescription)")
                        DispatchQueue.main.async { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

// MARK: - HomeView.swift (в стиле Happ: подписки прямо на главном)

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var settings: AppSettings
    var onPickServer: () -> Void

    @State private var showAdd = false
    @State private var showScan = false

    private var connected: Bool { vpn.status == .connected }

    private var statusText: String {
        switch vpn.status {
        case .connected: return "Защищено"
        case .connecting: return "Подключение…"
        case .reasserting: return "Переподключение…"
        case .disconnecting: return "Отключение…"
        default: return vpn.error == nil ? "Не подключено" : "Ошибка подключения"
        }
    }

    private func sorted(_ g: SubGroup) -> [Server] {
        guard settings.sortByPing else { return g.servers }
        func key(_ p: Int?) -> Int {
            guard let p = p else { return Int.max - 1 }
            return p < 0 ? Int.max : p
        }
        return g.servers.sorted { key(store.pings[$0.id]) < key(store.pings[$1.id]) }
    }

    private func pick(_ s: Server) {
        let changed = store.selected?.id != s.id
        store.selectedID = s.id
        if changed && vpn.isActive { vpn.switchServer(s) }
    }

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }

    private func trafficText(_ g: SubGroup) -> String? {
        var parts: [String] = []
        if let t = g.total { parts.append("\(fmt(g.used ?? 0)) / \(fmt(t))") }
        else if let u = g.used { parts.append("исп. \(fmt(u))") }
        if let e = g.expire {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateStyle = .short
            parts.append(e < Date() ? "истекла \(f.string(from: e))" : "до \(f.string(from: e))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func trafficFraction(_ g: SubGroup) -> Double? {
        guard let t = g.total, t > 0 else { return nil }
        return min(1, Double(g.used ?? 0) / Double(t))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Logo()

                // Кнопка подключения
                VStack(spacing: 12) {
                    Button {
                        vpn.toggle(server: store.selected)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.accent.opacity(connected ? 0.35 : 0.12))
                                .frame(width: 180, height: 180)
                                .blur(radius: 30)
                            Circle()
                                .stroke(Theme.accentLight.opacity(0.35), lineWidth: 1)
                                .frame(width: 150, height: 150)
                            Circle()
                                .fill(connected
                                      ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentDark],
                                                                     startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(Theme.card))
                                .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                                .frame(width: 120, height: 120)
                            Image(systemName: "power")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(connected ? .white : Theme.accentLight)
                        }
                    }
                    .buttonStyle(.plain)

                    Text(statusText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .legible()

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

                // Секция подписок (как в Happ)
                HStack(spacing: 10) {
                    Text("МОИ ПОДПИСКИ")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(0.8)
                        .foregroundColor(Theme.muted)
                        .padding(.leading, 4)
                    Spacer()
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        IconCircle(systemName: "arrow.clockwise", busy: !store.refreshing.isEmpty)
                    }
                    .buttonStyle(.plain)
                    Button {
                        showScan = true
                    } label: {
                        IconCircle(systemName: "qrcode.viewfinder")
                    }
                    .buttonStyle(.plain)
                    Button {
                        showAdd = true
                    } label: {
                        IconCircle(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                }

                if store.groups.isEmpty {
                    Text("Пока нет подписок. Нажмите «+», чтобы добавить, или отсканируйте QR-код.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.muted)
                        .padding(.top, 8)
                }

                // Список групп и серверов прямо на главном экране
                ForEach(store.groups) { g in
                    VStack(alignment: .leading, spacing: 10) {
                        // Заголовок подписки
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(g.name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button {
                                    Task { await store.pingAll(g.id) }
                                } label: {
                                    IconCircle(systemName: "bolt.fill",
                                               busy: store.pingingGroups.contains(g.id))
                                }
                                .buttonStyle(.plain)
                                if !g.url.isEmpty {
                                    Button {
                                        Task { await store.refresh(g.id) }
                                    } label: {
                                        IconCircle(systemName: "arrow.clockwise",
                                                   busy: store.refreshing.contains(g.id))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Menu {
                                    Button(role: .destructive) {
                                        store.removeGroup(g.id)
                                    } label: {
                                        Label("Удалить подписку", systemImage: "trash")
                                    }
                                } label: {
                                    IconCircle(systemName: "ellipsis")
                                }
                            }
                            if let info = trafficText(g) {
                                if let f = trafficFraction(g) {
                                    ProgressView(value: f)
                                        .tint(f > 0.9 ? Color(hex: 0xFB923C) : Theme.accent)
                                }
                                Text(info)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.muted)
                            }
                        }
                        .card()

                        // Серверы внутри подписки
                        ForEach(sorted(g)) { s in
                            Button { pick(s) } label: {
                                ServerRow(server: s,
                                          selected: store.selected?.id == s.id,
                                          ping: store.pings[s.id])
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.removeServer(s.id)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }

                Button("Управление подписками") { onPickServer() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showAdd) {
            AddSheet().environmentObject(store)
        }
        .fullScreenCover(isPresented: $showScan) {
            ScanSheet().environmentObject(store)
        }
    }
}

struct ServerPickerSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var onManage: () -> Void

    private func sorted(_ g: SubGroup) -> [Server] {
        guard settings.sortByPing else { return g.servers }
        func key(_ p: Int?) -> Int {
            guard let p = p else { return Int.max - 1 }
            return p < 0 ? Int.max : p
        }
        return g.servers.sorted { key(store.pings[$0.id]) < key(store.pings[$1.id]) }
    }

    private func pick(_ s: Server) {
        let changed = store.selected?.id != s.id
        store.selectedID = s.id
        if changed && vpn.isActive { vpn.switchServer(s) }
        dismiss()
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Выбор сервера")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        Task { for g in store.groups { await store.pingAll(g.id) } }
                    } label: {
                        IconCircle(systemName: "bolt.fill", busy: !store.pingingGroups.isEmpty)
                    }
                    .buttonStyle(.plain)
                }
                if vpn.isActive {
                    Text("При смене сервера подключение перезапустится. Пока VPN включён, пинг показывает задержку через него.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if store.groups.isEmpty {
                            Text("Серверов пока нет. Добавьте подписку на вкладке «Серверы».")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.muted)
                        }
                        ForEach(store.groups) { g in
                            Text(g.name.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .kerning(0.8)
                                .foregroundColor(Theme.muted)
                                .padding(.top, 6)
                            ForEach(sorted(g)) { sv in
                                Button { pick(sv) } label: {
                                    ServerRow(server: sv, selected: store.selected?.id == sv.id,
                                              ping: store.pings[sv.id])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button("Управление подписками") { onManage() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - AppSettings.swift

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
        case .eclipse, .custom: return "Eclipse/1.0"
        case .happ: return "Happ/3.0.0"
        case .v2rayn: return "v2rayN/7.0"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private static let keyPrefix = "eclipse.s."

    // подключение
    @Published var onDemand: Bool { didSet { save(onDemand, "onDemand") } }
    @Published var mtu: Int { didSet { save(mtu, "mtu") } }
    // DNS
    @Published var dnsPreset: DNSPreset { didSet { save(dnsPreset.rawValue, "dnsPreset") } }
    @Published var customDNS: String { didSet { save(customDNS, "customDNS") } }
    // маршрутизация
    @Published var bypassLAN: Bool { didSet { save(bypassLAN, "bypassLAN") } }
    @Published var directRules: String { didSet { save(directRules, "directRules") } }
    // гео-маршрутизация
    @Published var useGeoRouting: Bool { didSet { save(useGeoRouting, "useGeoRouting") } }
    @Published var geoipDirect: String { didSet { save(geoipDirect, "geoipDirect") } }
    @Published var geositeDirect: String { didSet { save(geositeDirect, "geositeDirect") } }
    // ядро
    @Published var sniffing: Bool { didSet { save(sniffing, "sniffing") } }
    @Published var mux: Bool { didSet { save(mux, "mux") } }
    @Published var fragment: Bool { didSet { save(fragment, "fragment") } }
    // производительность
    @Published var memoryLimit: Int { didSet { save(memoryLimit, "memoryLimit") } }
    // подписки
    @Published var autoUpdate: Bool { didSet { save(autoUpdate, "autoUpdate") } }
    @Published var updateHours: Int { didSet { save(updateHours, "updateHours") } }
    @Published var requestTimeout: Int { didSet { save(requestTimeout, "requestTimeout") } }
    @Published var uaPreset: UAPreset { didSet { save(uaPreset.rawValue, "uaPreset") } }
    @Published var customUA: String { didSet { save(customUA, "customUA") } }
    @Published var sendHWID: Bool { didSet { save(sendHWID, "sendHWID") } }
    @Published var sortByPing: Bool { didSet { save(sortByPing, "sortByPing") } }

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
    }

    // MARK: производные значения

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
        o.memoryLimit = memoryLimit   // <- передаём лимит памяти в расширение

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

    // Заголовки запроса подписки (HWID — как у Happ: нужен провайдерам с привязкой к устройству)
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

// MARK: - SettingsView.swift

struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold))
                .kerning(0.8)
                .foregroundColor(Theme.muted)
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
                    .foregroundColor(.white)
                if let s = subtitle {
                    Text(s)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
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
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Menu {
                ForEach(options.indices, id: \.self) { i in
                    Button(options[i].1) { selection = options[i].0 }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(options.first(where: { $0.0 == selection })?.1 ?? "—")
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
            .foregroundColor(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
    }
}

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @EnvironmentObject var settings: AppSettings
    @State private var log = ""
    @State private var copied = false
    @State private var confirmReset = false

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

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func row(_ k: String, _ v: String, bad: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(k)
                .font(.system(size: 13))
                .foregroundColor(Theme.muted)
            Spacer(minLength: 12)
            Text(v)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(bad ? Color(hex: 0xFF8A8A) : .white)
                .multilineTextAlignment(.trailing)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Logo()
                Text("Настройки")
                    .font(.system(size: 34, weight: .bold))
                    .kerning(-1)
                    .foregroundColor(.white)
                    .legible()

                SettingsSection("Подключение",
                                footer: "Изменения применяются при следующем подключении.") {
                    ToggleRow(title: "Блокировать трафик при обрыве",
                              subtitle: "Kill-switch: без VPN интернет не работает",
                              isOn: $vpn.killSwitch, disabled: vpn.isActive)
                    ToggleRow(title: "Автоподключение",
                              subtitle: "iOS сама включит VPN, когда появится сеть",
                              isOn: $settings.onDemand)
                    MenuRow(title: "MTU", selection: $settings.mtu,
                            options: [(1280, "1280"), (1400, "1400"), (1500, "1500")])
                }

                SettingsSection("DNS",
                                footer: "Используется и системой, и ядром. Для своего DNS укажите IP-адреса через запятую.") {
                    MenuRow(title: "Сервер", selection: $settings.dnsPreset,
                            options: DNSPreset.allCases.map { ($0, $0.title) })
                    if settings.dnsPreset == .custom {
                        SettingsField(placeholder: "1.1.1.1, 8.8.8.8", text: $settings.customDNS)
                    }
                }

                SettingsSection("Маршрутизация",
                                footer: "По одному правилу в строке: домен (example.com), IP или подсеть (10.0.0.0/8). Эти адреса идут напрямую, мимо VPN. Для доменов нужен включённый sniffing.") {
                    ToggleRow(title: "Локальные сети напрямую",
                              subtitle: "10.x, 172.16.x, 192.168.x — без VPN",
                              isOn: $settings.bypassLAN)
                    ZStack(alignment: .topLeading) {
                        if settings.directRules.isEmpty {
                            Text("example.com\n192.168.1.0/24")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(Theme.muted.opacity(0.6))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $settings.directRules)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .frame(minHeight: 90)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))
                }

                SettingsSection("Маршрутизация (Geo)",
                                footer: "Автоматический обход по базам GeoIP/GeoSite. Укажите коды через запятую (например: ru, cn или category-ads-all, private). Базы скачиваются автоматически при первой загрузке подписки.") {
                    ToggleRow(title: "Использовать GeoIP/GeoSite",
                              subtitle: "Направлять трафик напрямую по базам",
                              isOn: $settings.useGeoRouting)
                    if settings.useGeoRouting {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GeoIP напрямую")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.muted)
                            SettingsField(placeholder: "ru, cn", text: $settings.geoipDirect)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GeoSite напрямую")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.muted)
                            SettingsField(placeholder: "category-ads-all, private", text: $settings.geositeDirect)
                        }
                    }
                }

                SettingsSection("Ядро",
                                footer: "Mux и фрагментация могут увеличить расход памяти расширения. Включайте по необходимости.") {
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

                SettingsSection("Производительность",
                                footer: "Ограничение памяти для ядра Xray. Маленькое значение может привести к сбоям на слабых устройствах, большое — к повышенному расходу батареи.") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Лимит памяти")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(settings.memoryLimit) МБ")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.accentLight)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.memoryLimit) },
                            set: { settings.memoryLimit = Int($0) }
                        ), in: 10...256, step: 10)
                        .tint(Theme.accent)
                    }
                }

                SettingsSection("Подписки",
                                footer: "HWID — идентификатор этого устройства. Некоторые провайдеры используют его, чтобы привязать подписку к устройству. Отправляйте, только если сервис этого требует.") {
                    ToggleRow(title: "Автообновление",
                              subtitle: "При запуске приложения",
                              isOn: $settings.autoUpdate)
                    if settings.autoUpdate {
                        MenuRow(title: "Не чаще, чем раз в", selection: $settings.updateHours,
                                options: [(6, "6 ч"), (12, "12 ч"), (24, "24 ч"), (48, "48 ч")])
                    }
                    MenuRow(title: "Таймаут запроса", selection: $settings.requestTimeout,
                            options: [(10, "10 с"), (20, "20 с"), (30, "30 с"), (60, "60 с")])
                    MenuRow(title: "User-Agent", selection: $settings.uaPreset,
                            options: UAPreset.allCases.map { ($0, $0.title) })
                    if settings.uaPreset == .custom {
                        SettingsField(placeholder: "Например, MyClient/1.0", text: $settings.customUA)
                    }
                    ToggleRow(title: "Отправлять HWID",
                              subtitle: "Заголовки x-hwid и данные об устройстве",
                              isOn: $settings.sendHWID)
                    ToggleRow(title: "Сортировать серверы по пингу",
                              subtitle: "Сначала самые быстрые",
                              isOn: $settings.sortByPing)
                }

                SettingsSection("Диагностика") {
                    row("iOS", UIDevice.current.systemVersion)
                    row("Статус VPN", statusName)
                    row("Приложение", Bundle.main.bundleIdentifier ?? "—")
                    row("Расширение (встроено)", vpn.embeddedExtensionID ?? "не найдено",
                        bad: vpn.embeddedExtensionID == nil)
                    row("App Group", AppGroup.available ? "доступна" : "недоступна",
                        bad: !AppGroup.available)
                    row("Лог расширения", AppGroup.available ? "виден" : "не виден (нужна App Group)")
                    row("Geo-базы", GeoDat.available ? "есть" : "нет",
                        bad: !GeoDat.available)
                    if let e = vpn.error { row("Последняя ошибка", e, bad: true) }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("ЖУРНАЛ")
                            .font(.system(size: 12, weight: .bold))
                            .kerning(0.8)
                            .foregroundColor(Theme.muted)
                            .padding(.leading, 4)
                        Spacer()
                        Button { log = SharedLog.read() } label: {
                            IconCircle(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        Button(copied ? "Скопировано" : "Копировать") {
                            UIPasteboard.general.string = log
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Очистить") {
                            SharedLog.clear()
                            log = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Text(log.isEmpty ? "Журнал пуст" : log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(log.isEmpty ? Theme.muted : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .card()
                }

                SettingsSection("О приложении") {
                    row("Eclipse", version)
                    Button("Сбросить настройки") { confirmReset = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .confirmationDialog("Сбросить все настройки?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { settings.reset() }
        }
        .onAppear { log = SharedLog.read() }
        .onChange(of: vpn.status) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { log = SharedLog.read() }
        }
    }
}

// MARK: - ServersView.swift

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
                        .foregroundColor(.white)
                        .legible()
                    Spacer()
                    Button {
                        Task { await store.refreshAll() }
                    } label: {
                        IconCircle(systemName: "arrow.clockwise", busy: !store.refreshing.isEmpty)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    Button("Добавить подписку") { showAdd = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button {
                        showScan = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 22))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 64)
                }

                if let msg = store.message {
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: 0xFF8A8A))
                }

                if store.groups.isEmpty {
                    Text("Пока пусто. Добавьте ссылку подписки, отсканируйте QR-код или вставьте ссылку vless:// / vmess:// / trojan:// / ss://.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.muted)
                        .padding(.top, 8)
                }

                ForEach(store.groups) { g in
                    GroupSection(group: g, collapsed: collapsed.contains(g.id)) {
                        if collapsed.contains(g.id) { collapsed.remove(g.id) } else { collapsed.insert(g.id) }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showAdd) {
            AddSheet().environmentObject(store)
        }
        .fullScreenCover(isPresented: $showScan) {
            ScanSheet().environmentObject(store)
        }
    }
}

struct GroupSection: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var vpn: VPNController
    let group: SubGroup
    let collapsed: Bool
    let toggle: () -> Void

    private var subtitle: String {
        let count = "\(group.servers.count) серв."
        if group.url.isEmpty { return "\(count) · добавлены вручную" }
        guard let d = group.updatedAt else { return "\(count) · не обновлялась" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "ru_RU")
        return "\(count) · обновлено \(f.localizedString(for: d, relativeTo: Date()))"
    }

    private func fmt(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }

    private var trafficText: String? {
        var parts: [String] = []
        if let t = group.total { parts.append("\(fmt(group.used ?? 0)) из \(fmt(t))") }
        else if let u = group.used { parts.append("израсходовано \(fmt(u))") }
        if let e = group.expire {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ru_RU")
            f.dateStyle = .medium
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
            guard let p = p else { return Int.max - 1 }   // без замера — после рабочих
            return p < 0 ? Int.max : p                    // недоступные — в конец
        }
        return group.servers.sorted { key(store.pings[$0.id]) < key(store.pings[$1.id]) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(Theme.muted)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundColor(Theme.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    Task { await store.pingAll(group.id) }
                } label: {
                    IconCircle(systemName: "bolt.fill", busy: store.pingingGroups.contains(group.id))
                }
                .buttonStyle(.plain)

                if !group.url.isEmpty {
                    Button {
                        Task { await store.refresh(group.id) }
                    } label: {
                        IconCircle(systemName: "arrow.clockwise", busy: store.refreshing.contains(group.id))
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button(role: .destructive) {
                        store.removeGroup(group.id)
                    } label: {
                        Label("Удалить подписку", systemImage: "trash")
                    }
                } label: {
                    IconCircle(systemName: "ellipsis")
                }
            }
            .card()

            if let info = trafficText {
                VStack(alignment: .leading, spacing: 8) {
                    if let f = trafficFraction {
                        ProgressView(value: f).tint(f > 0.9 ? Color(hex: 0xFB923C) : Theme.accent)
                    }
                    Text(info)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }

            if !collapsed {
                ForEach(serversSorted) { s in
                    Button {
                        if store.selected?.id != s.id {
                            store.selectedID = s.id
                            if vpn.isActive { vpn.switchServer(s) }
                        }
                    } label: {
                        ServerRow(server: s, selected: store.selected?.id == s.id, ping: store.pings[s.id])
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            store.removeServer(s.id)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

struct ServerRow: View {
    let server: Server
    let selected: Bool
    let ping: Int?

    private var pingColor: Color {
        guard let p = ping else { return Theme.muted }
        if p < 0 { return Color(hex: 0xFF8A8A) }
        if p < 150 { return Color(hex: 0x4ADE80) }
        if p < 400 { return Color(hex: 0xFACC15) }
        return Color(hex: 0xFB923C)
    }

    private var pingText: String? {
        guard let p = ping else { return nil }
        return p < 0 ? "×" : "\(p) мс"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(server.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(server.protocolLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accentLight)
                HStack(spacing: 6) {
                    if let t = server.transportLabel { Chip(text: t) }
                    if let sec = server.securityLabel { Chip(text: sec) }
                }
            }
            Spacer()
            if let t = pingText {
                Text(t)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(pingColor)
            }
        }
        .card(selected: selected)
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
                Text("В приложении нет описания доступа к камере (NSCameraUsageDescription). Добавьте его в project.yml и пересоберите. Пока можно выбрать QR из фото.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                    .padding(32)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(12)
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
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Выбрать из фото") { showPhoto = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showPhoto) {
            PhotoQRPicker { code in
                showPhoto = false
                if let code = code { handle(code) } else { status = "QR-код на фото не найден" }
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

struct AddSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Добавить")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                Text("Ссылка подписки (https://…) или отдельная ссылка сервера (vless://, vmess://, trojan://, ss://)")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.muted)

                TextField("Вставьте ссылку", text: $text)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .foregroundColor(.white)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 1))

                Button("Вставить из буфера") {
                    if let s = UIPasteboard.general.string { text = s }
                }
                .buttonStyle(SecondaryButtonStyle())

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
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: 0xFF8A8A))
                }
                Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Scanner.swift

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
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
        case .authorized:
            setup()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.setup() } }
            }
        default:
            break
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
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !found,
              let o = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let s = o.stringValue else { return }
        found = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCode?(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.found = false }
    }
}

// Выбор QR из галереи (скриншот подписки)
struct PhotoQRPicker: UIViewControllerRepresentable {
    var onCode: (String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
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
                  item.canLoadObject(ofClass: UIImage.self) else {
                onCode(nil)
                return
            }
            item.loadObject(ofClass: UIImage.self) { obj, _ in
                var code: String?
                if let img = obj as? UIImage, let ci = CIImage(image: img) {
                    let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                         options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
                    let feats = det?.features(in: ci) as? [CIQRCodeFeature]
                    code = feats?.first?.messageString
                }
                DispatchQueue.main.async { self.onCode(code) }
            }
        }
    }
}
