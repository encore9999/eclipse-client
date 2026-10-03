import SwiftUI
import NetworkExtension
import Foundation

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
        HStack(spacing: 0) {
            Text("encore").foregroundColor(.white)
            Text("VPN").foregroundColor(Theme.accentLight)
        }
        .font(.system(size: 22, weight: .bold))
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

// MARK: - Models.swift

struct Server: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var proto: String
    var host: String
    var port: Int
    var link: String
}

enum LinkParser {
    static func decodeBase64(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func parse(_ line: String) -> Server? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "://") else { return nil }
        let scheme = s[..<r.lowerBound].lowercased()
        switch scheme {
        case "vless", "trojan": return parseURLStyle(s, proto: scheme)
        case "vmess": return parseVMess(s)
        case "ss": return parseSS(s)
        default: return nil
        }
    }

    static func parseSubscription(_ text: String) -> [Server] {
        var body = text
        if !body.contains("://") {
            body = decodeBase64(text) ?? ""
        }
        return body
            .components(separatedBy: CharacterSet.newlines)
            .compactMap { parse($0) }
    }

    private static func splitHostPort(_ hp: String) -> (String, Int)? {
        if hp.hasPrefix("["), let end = hp.firstIndex(of: "]") {
            let host = String(hp[hp.index(after: hp.startIndex)..<end])
            let rest = hp[hp.index(after: end)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let idx = hp.lastIndex(of: ":"),
              let port = Int(hp[hp.index(after: idx)...]) else { return nil }
        return (String(hp[..<idx]), port)
    }

    private static func splitFragment(_ s: String) -> (String, String) {
        guard let h = s.firstIndex(of: "#") else { return (s, "") }
        let raw = String(s[s.index(after: h)...])
        return (String(s[..<h]), raw.removingPercentEncoding ?? raw)
    }

    private static func parseURLStyle(_ s: String, proto: String) -> Server? {
        let (body, name) = splitFragment(s)
        guard let sch = body.range(of: "://") else { return nil }
        var rest = String(body[sch.upperBound...])
        if let q = rest.firstIndex(of: "?") { rest = String(rest[..<q]) }
        if let sl = rest.firstIndex(of: "/") { rest = String(rest[..<sl]) }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let hp = String(rest[rest.index(after: at)...])
        guard let (host, port) = splitHostPort(hp) else { return nil }
        return Server(name: name.isEmpty ? host : name, proto: proto, host: host, port: port, link: s)
    }

    private static func parseVMess(_ s: String) -> Server? {
        let payload = String(s.dropFirst("vmess://".count))
        guard let json = decodeBase64(payload),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let host = obj["add"] as? String else { return nil }
        var port = 0
        if let p = obj["port"] as? Int { port = p }
        else if let p = obj["port"] as? String, let n = Int(p) { port = n }
        guard port > 0 else { return nil }
        let name = (obj["ps"] as? String) ?? host
        return Server(name: name.isEmpty ? host : name, proto: "vmess", host: host, port: port, link: s)
    }

    private static func parseSS(_ s: String) -> Server? {
        let (body0, name) = splitFragment(s)
        var body = String(body0.dropFirst("ss://".count))
        if let q = body.firstIndex(of: "?") { body = String(body[..<q]) }
        if let sl = body.firstIndex(of: "/") { body = String(body[..<sl]) }
        var hostPort: String?
        if body.contains("@") {
            if let at = body.lastIndex(of: "@") { hostPort = String(body[body.index(after: at)...]) }
        } else if let decoded = decodeBase64(body), let at = decoded.lastIndex(of: "@") {
            hostPort = String(decoded[decoded.index(after: at)...])
        }
        guard let hp = hostPort, let (host, port) = splitHostPort(hp) else { return nil }
        return Server(name: name.isEmpty ? host : name, proto: "ss", host: host, port: port, link: s)
    }
}

// MARK: - Store.swift

final class Store: ObservableObject {
    @Published var servers: [Server] = [] { didSet { save() } }
    @Published var selectedID: UUID? { didSet { save() } }
    @Published var subscriptionURL: String = "" { didSet { save() } }
    @Published var isLoading = false
    @Published var message: String?

    private struct Saved: Codable {
        var servers: [Server]
        var selectedID: UUID?
        var subscriptionURL: String
    }
    private let key = "encore.store.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            servers = saved.servers
            selectedID = saved.selectedID
            subscriptionURL = saved.subscriptionURL
        }
    }

    private func save() {
        let saved = Saved(servers: servers, selectedID: selectedID, subscriptionURL: subscriptionURL)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    var selected: Server? {
        servers.first { $0.id == selectedID } ?? servers.first
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        if selectedID == server.id { selectedID = servers.first?.id }
    }

    @MainActor
    func add(_ input: String) async -> Bool {
        message = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let single = LinkParser.parse(text) {
            servers.append(single)
            selectedID = single.id
            return true
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            subscriptionURL = text
            return await refresh()
        }
        message = "Не похоже на ссылку подписки или сервера"
        return false
    }

    @MainActor
    @discardableResult
    func refresh() async -> Bool {
        guard let url = URL(string: subscriptionURL) else {
            message = "Подписка не добавлена"
            return false
        }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            var req = URLRequest(url: url)
            req.setValue("encoreVPN/1.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            let text = String(data: data, encoding: .utf8) ?? ""
            let parsed = LinkParser.parseSubscription(text)
            if parsed.isEmpty {
                message = "В подписке не найдено серверов"
                return false
            }
            let oldLink = selected?.link
            servers = parsed
            selectedID = (parsed.first { $0.link == oldLink } ?? parsed[0]).id
            return true
        } catch {
            message = "Ошибка загрузки: \(error.localizedDescription)"
            return false
        }
    }
}

// MARK: - VPNController.swift

final class VPNController: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var error: String?
    private var manager: NETunnelProviderManager?

    init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.status = self.manager?.connection.status ?? .disconnected
        }
    }

    func load() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.manager = managers?.first
                self.status = self.manager?.connection.status ?? .disconnected
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
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self = self else { return }
            let m = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
            proto.serverAddress = server.host
            proto.providerConfiguration = ["link": server.link, "name": server.name]
            m.protocolConfiguration = proto
            m.localizedDescription = "encoreVPN"
            m.isEnabled = true
            m.saveToPreferences { saveError in
                if let saveError = saveError {
                    DispatchQueue.main.async {
                        self.error = "Не удалось сохранить VPN: \(saveError.localizedDescription)"
                    }
                    return
                }
                m.loadFromPreferences { _ in
                    DispatchQueue.main.async { self.manager = m }
                    do {
                        try m.connection.startVPNTunnel()
                    } catch {
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
        case .connecting, .reasserting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        default: return "Не подключено"
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
            }
            .frame(maxWidth: .infinity)

            Spacer()

            Button(action: onPickServer) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.selected?.name ?? "Сервер не выбран")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(store.selected.map { "\($0.proto.uppercased()) · \($0.host):\($0.port)" }
                             ?? "Добавьте подписку на вкладке «Серверы»")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                            .lineLimit(1)
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

// MARK: - ServersView.swift

struct ServersView: View {
    @EnvironmentObject var store: Store
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Logo()
                Text("Серверы")
                    .font(.system(size: 34, weight: .bold))
                    .kerning(-1)
                    .foregroundColor(.white)

                if !store.subscriptionURL.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ПОДПИСКА")
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(1.5)
                            .foregroundColor(Theme.muted)
                        Text(store.subscriptionURL)
                            .font(.system(size: 13))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            HStack {
                                if store.isLoading { ProgressView().tint(.white) }
                                Text(store.isLoading ? "Обновление…" : "Обновить")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(store.isLoading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                Button("Добавить подписку или ссылку") { showAdd = true }
                    .buttonStyle(PrimaryButtonStyle())

                if let msg = store.message {
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: 0xFF8A8A))
                }

                if store.servers.isEmpty {
                    Text("Пока пусто. Вставьте ссылку подписки или vless:// / vmess:// / trojan:// / ss:// ссылку.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.muted)
                        .padding(.top, 8)
                }

                ForEach(store.servers) { s in
                    Button {
                        store.selectedID = s.id
                    } label: {
                        ServerRow(server: s, selected: store.selected?.id == s.id)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            store.remove(s)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
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
    }
}

struct ServerRow: View {
    let server: Server
    let selected: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(server.host):\(server.port)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(server.proto.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.accentLight)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent.opacity(0.18)))
        }
        .card(selected: selected)
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
