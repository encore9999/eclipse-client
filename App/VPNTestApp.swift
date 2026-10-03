import SwiftUI
import NetworkExtension

@main
struct VPNTestApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class VPNController: ObservableObject {
    @Published var status = "—"
    @Published var log = ""
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    func add(_ s: String) { DispatchQueue.main.async { self.log += s + "\n" } }

    func setup() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error { self.add("load error: \(error.localizedDescription)") }
            let m = managers?.first ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".tunnel"
            proto.serverAddress = "test"
            m.protocolConfiguration = proto
            m.localizedDescription = "VPNTest"
            m.isEnabled = true
            m.saveToPreferences { error in
                if let error = error {
                    self.add("SAVE ERROR: \(error.localizedDescription)")
                    self.add("=> скорее всего, в профиле нет Network Extension")
                    return
                }
                self.add("OK: конфигурация VPN сохранена (iOS могла спросить разрешение)")
                m.loadFromPreferences { _ in
                    self.manager = m
                    self.watch(m)
                    self.update(m)
                }
            }
        }
    }

    func connect() {
        guard let m = manager else { add("сначала нажмите «Установить конфигурацию»"); return }
        do {
            try m.connection.startVPNTunnel()
            add("startVPNTunnel вызван")
        } catch {
            add("START ERROR: \(error.localizedDescription)")
        }
    }

    func disconnect() { manager?.connection.stopVPNTunnel() }

    private func watch(_ m: NETunnelProviderManager) {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: m.connection, queue: .main
        ) { [weak self] _ in self?.update(m) }
    }

    private func update(_ m: NETunnelProviderManager) {
        let names: [NEVPNStatus: String] = [
            .invalid: "invalid", .disconnected: "disconnected", .connecting: "connecting",
            .connected: "CONNECTED", .reasserting: "reasserting", .disconnecting: "disconnecting"
        ]
        DispatchQueue.main.async { self.status = names[m.connection.status] ?? "?" }
    }
}

struct ContentView: View {
    @StateObject private var vpn = VPNController()
    var body: some View {
        VStack(spacing: 16) {
            Text("Статус: \(vpn.status)").font(.title2)
            Button("1. Установить конфигурацию") { vpn.setup() }
            Button("2. Подключить") { vpn.connect() }
            Button("3. Отключить") { vpn.disconnect() }
            ScrollView {
                Text(vpn.log).font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }
}
