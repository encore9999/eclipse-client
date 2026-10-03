import SwiftUI
import NetworkExtension
import Foundation
import AVFoundation
import PhotosUI
import CoreImage

// Server, LinkParser, Pinger, AppGroup, TunnelKeys, SharedLog и XrayConfigBuilder
// лежат в папке Shared/ (компилируются и в приложение, и в расширение).

// MARK: - VPNTestApp.swift

@main
struct EncoreApp: App {
    @StateObject private var store = Store()
    @StateObject private var vpn = VPNController()

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 10/255, green: 7/255, blue: 20/255, alpha: 1)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(vpn)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var vpn: VPNController
    @State private var tab = 0

    var body: some View {
        ZStack {
            AppBackground()
            TabView(selection: $tab) {
                HomeView(onPickServer: { tab = 1 })
                    .tabItem { Label("Главная", systemImage: "shield.lefthalf.filled") }
                    .tag(0)
                ServersView()
                    .tabItem { Label("Серверы", systemImage: "globe") }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
                    .tag(2)
            }
            .accentColor(Theme.accentLight)
        }
        .onAppear { vpn.load() }
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
    static let bg = Color(hex: 0x0A0714)
    static let bg2 = Color(hex: 0x140E2B)
    static let card = Color(hex: 0x15121F)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(hex: 0x6D4DFF)
    static let accentDark = Color(hex: 0x4B2FD6)
    static let accentLight = Color(hex: 0xA68BFF)
    static let muted = Color(hex: 0x9E97B8)
}

// Грань изометрического куба: 0 — верх, 1 — правая, 2 — левая
struct CubeFace: Shape {
    let face: Int
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        func v(_ deg: Double) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(deg * Double.pi / 180)),
                    y: c.y + r * CGFloat(sin(deg * Double.pi / 180)))
        }
        let top = v(-90), ur = v(-30), lr = v(30), bot = v(90), ll = v(150), ul = v(210)
        var p = Path()
        switch face {
        case 0: p.addLines([top, ur, c, ul])
        case 1: p.addLines([ur, lr, bot, c])
        default: p.addLines([bot, ll, ul, c])
        }
        p.closeSubpath()
        return p
    }
}

struct GlassCube: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            CubeFace(face: 0).fill(Theme.accent.opacity(0.18))
            CubeFace(face: 1).fill(Theme.accent.opacity(0.08))
            CubeFace(face: 2).fill(Theme.accent.opacity(0.26))
            CubeFace(face: 0).stroke(Theme.accentLight.opacity(0.45), lineWidth: 1)
            CubeFace(face: 1).stroke(Theme.accentLight.opacity(0.45), lineWidth: 1)
            CubeFace(face: 2).stroke(Theme.accentLight.opacity(0.45), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.5), radius: 14)
    }
}

struct AppBackground: View {
    @State private var float = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bg2, Theme.bg], startPoint: .top, endPoint: .bottom)
            WaveLines().allowsHitTesting(false)
            GeometryReader { g in
                ZStack {
                    GlassCube(size: 90)
                        .rotationEffect(.degrees(12))
                        .position(x: g.size.width * 0.88, y: g.size.height * 0.10)
                        .offset(y: float ? 8 : -8)
                    GlassCube(size: 60)
                        .rotationEffect(.degrees(-18))
                        .position(x: g.size.width * 0.07, y: g.size.height * 0.40)
                        .offset(y: float ? -6 : 6)
                    GlassCube(size: 110)
                        .rotationEffect(.degrees(20))
                        .position(x: g.size.width * 0.95, y: g.size.height * 0.80)
                        .offset(y: float ? 10 : -10)
                }
                .opacity(0.75)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { float = true }
        }
    }
}

struct Logo: View {
    var body: some View {
        Text("Eclipse")
            .font(.system(size: 22, weight: .bold))
            .kerning(-0.5)
            .foregroundColor(.white)
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
            .background(RoundedRectangle(cornerRadius: 20).fill(Theme.card.opacity(0.92)))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
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

// Тонкие волнистые линии на фоне (как на сайте), рисуются через Canvas
struct WaveLines: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let lines = 14
                for i in 0..<lines {
                    var path = Path()
                    let baseY = size.height * (CGFloat(i) + 0.5) / CGFloat(lines)
                    let amp = 14 + CGFloat(i % 4) * 5
                    let phase = Double(i) * 0.55 + t * 0.25
                    path.move(to: CGPoint(x: 0, y: baseY))
                    var x: CGFloat = 0
                    while x <= size.width + 6 {
                        let w1 = sin(Double(x) / 90 + phase)
                        let w2 = sin(Double(x) / 40 - phase * 1.3)
                        let y = baseY + amp * CGFloat(w1) + amp * 0.5 * CGFloat(w2)
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 6
                    }
                    ctx.stroke(path, with: .color(Theme.accentLight.opacity(0.07)), lineWidth: 1)
                }
            }
        }
        .ignoresSafeArea()
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
            req.setValue("Eclipse/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
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
            if let t = profileTitle(response) { groups[i].name = t }
            if !allServers.contains(where: { $0.id == selectedID }) {
                selectedID = allServers.first(where: { $0.link == selectedLink })?.id ?? allServers.first?.id
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

    func toggle(server: Server?) {
        if isActive {
            userStopped = true
            SharedLog.write("[app] пользователь отключил VPN")
            manager?.connection.stopVPNTunnel()
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
            profile = try XrayConfigBuilder.build(for: server, logPath: nil)
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
                TunnelKeys.serverPort: server.port
            ]
            // Kill-switch средствами iOS: при падении туннеля трафик блокируется
            proto.includeAllNetworks = self.killSwitch
            proto.excludeLocalNetworks = true
            m.protocolConfiguration = proto
            m.localizedDescription = "Eclipse"
            m.isEnabled = true
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

// MARK: - HomeView.swift

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var vpn: VPNController
    var onPickServer: () -> Void

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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Logo()

            VStack(alignment: .leading, spacing: 0) {
                Text("Просто\nработает.")
                    .font(.system(size: 46, weight: .bold))
                    .kerning(-1.5)
                    .foregroundColor(.white)
                Text("Дёшево и надёжно.")
                    .font(.system(size: 24, weight: .bold).italic())
                    .foregroundColor(Theme.accentLight)
            }

            Spacer()

            VStack(spacing: 14) {
                Button {
                    vpn.toggle(server: store.selected)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Theme.accent.opacity(connected ? 0.35 : 0.12))
                            .frame(width: 230, height: 230)
                            .blur(radius: 30)
                        Circle()
                            .stroke(Theme.accentLight.opacity(0.35), lineWidth: 1)
                            .frame(width: 190, height: 190)
                        Circle()
                            .fill(connected
                                  ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentDark],
                                                                 startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Theme.card))
                            .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                            .frame(width: 150, height: 150)
                        Image(systemName: "power")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundColor(connected ? .white : Theme.accentLight)
                    }
                }
                .buttonStyle(.plain)

                Text(statusText)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                if let err = vpn.error {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: 0xFF8A8A))
                        .multilineTextAlignment(.center)
                }

                // Kill-switch (includeAllNetworks): применяется при следующем подключении
                Toggle(isOn: $vpn.killSwitch) {
                    Text("Блокировать трафик при обрыве")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted)
                }
                .tint(Theme.accent)
                .disabled(vpn.isActive)
                .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            Button(action: onPickServer) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.selected?.name ?? "Сервер не выбран")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let s = store.selected {
                            Text(s.protocolLabel)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.accentLight)
                            HStack(spacing: 6) {
                                if let t = s.transportLabel { Chip(text: t) }
                                if let sec = s.securityLabel { Chip(text: sec) }
                            }
                        } else {
                            Text("Добавьте подписку на вкладке «Серверы»")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(Theme.muted)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - SettingsView.swift

struct SettingsView: View {
    @EnvironmentObject var vpn: VPNController
    @State private var log = ""
    @State private var copied = false

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
            VStack(alignment: .leading, spacing: 16) {
                Logo()
                Text("Настройки")
                    .font(.system(size: 34, weight: .bold))
                    .kerning(-1)
                    .foregroundColor(.white)

                Toggle(isOn: $vpn.killSwitch) {
                    Text("Блокировать трафик при обрыве")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                }
                .tint(Theme.accent)
                .disabled(vpn.isActive)
                .card()

                Text("Диагностика")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                VStack(spacing: 10) {
                    row("iOS", UIDevice.current.systemVersion)
                    row("Статус VPN", statusName)
                    row("Приложение", Bundle.main.bundleIdentifier ?? "—")
                    row("Расширение (встроено)", vpn.embeddedExtensionID ?? "не найдено",
                        bad: vpn.embeddedExtensionID == nil)
                    row("App Group", AppGroup.available ? "доступна" : "недоступна",
                        bad: !AppGroup.available)
                    row("Лог расширения", AppGroup.available ? "виден" : "не виден (нужна App Group)")
                    if let e = vpn.error { row("Последняя ошибка", e, bad: true) }
                }
                .card()

                HStack {
                    Text("Журнал")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
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
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
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

            if !collapsed {
                ForEach(group.servers) { s in
                    Button {
                        store.selectedID = s.id
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
