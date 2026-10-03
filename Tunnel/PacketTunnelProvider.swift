import NetworkExtension
import Network
import Xray
import Tun2SocksKit

enum TunnelError: LocalizedError {
    case badConfig, serverUnreachable(String), xray(String), settings(String), tun2socks(Int32)
    var errorDescription: String? {
        switch self {
        case .badConfig: return "Некорректная конфигурация туннеля"
        case .serverUnreachable(let h): return "Сервер недоступен: \(h)"
        case .xray(let m): return "Ошибка Xray: \(m)"
        case .settings(let m): return "Не удалось применить сетевые настройки: \(m)"
        case .tun2socks(let c): return "Туннель остановился (код \(c))"
        }
    }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private struct Cfg {
        let json: String, port: Int, user: String, pass: String, host: String, serverPort: Int
        init?(_ p: [String: Any]?) {
            guard let p = p,
                  let j = p[TunnelKeys.xrayConfig] as? String,
                  let port = p[TunnelKeys.socksPort] as? Int,
                  let u = p[TunnelKeys.socksUser] as? String,
                  let pw = p[TunnelKeys.socksPass] as? String,
                  let h = p[TunnelKeys.serverHost] as? String,
                  let sp = p[TunnelKeys.serverPort] as? Int else { return nil }
            json = j; self.port = port; user = u; pass = pw; host = h; serverPort = sp
        }
    }

    private let queue = DispatchQueue(label: "eclipse.tunnel.q")
    private var cfg: Cfg?
    private var monitor: NWPathMonitor?
    private var lastSignature: String?
    private var restartWork: DispatchWorkItem?
    private var stopping = false

    // MARK: start

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        AppGroup.defaults.removeObject(forKey: TunnelKeys.lastError)
        SharedLog.clear()
        stopping = false
        log("startTunnel, xray \(XraybridgeVersion())")

        let proto = protocolConfiguration as? NETunnelProviderProtocol
        guard let c = Cfg(proto?.providerConfiguration) else {
            return fail(TunnelError.badConfig, completionHandler)
        }
        cfg = c

        Task {
            do {
                // 1. Preflight: до туннеля сокеты расширения идут напрямую
                guard await Pinger.ping(host: c.host, port: c.serverPort, timeout: 5) != nil else {
                    throw TunnelError.serverUnreachable(c.host)
                }
                // 2. Ядро
                try startXray()
                // 3. utun, DNS, маршруты
                do { try await setTunnelNetworkSettings(makeSettings(c)) }
                catch { throw TunnelError.settings(error.localizedDescription) }
                // 4. tun2socks по fd utun
                startTun2Socks(c)
                // 5. Мониторинг сети
                startMonitor()
                log("tunnel up")
                completionHandler(nil)   // только теперь NEVPNStatus станет .connected
            } catch {
                XraybridgeStop()
                fail(error, completionHandler)
            }
        }
    }

    // MARK: stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("stopTunnel reason=\(reason.rawValue)")
        stopping = true
        restartWork?.cancel()
        monitor?.cancel(); monitor = nil
        Socks5Tunnel.quit()
        XraybridgeStop()
        completionHandler()
    }

    // MARK: Xray

    private func startXray() throws {
        guard let c = cfg else { throw TunnelError.badConfig }
        let dir = AppGroup.container.appendingPathComponent("xray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { try XraybridgeStart(c.json, dir.path) }
        catch { throw TunnelError.xray(error.localizedDescription) }
        log("xray started")
    }

    private func restartXray() {
        guard !stopping else { return }
        log("network changed → restart xray")
        reasserting = true
        XraybridgeStop()
        do { try startXray() }
        catch {
            AppGroup.defaults.set(error.localizedDescription, forKey: TunnelKeys.lastError)
            cancelTunnelWithError(error)
            return
        }
        reasserting = false
    }

    // MARK: tun2socks

    private func startTun2Socks(_ c: Cfg) {
        let yaml = """
        tunnel:
          mtu: 1400
          ipv4: 198.18.0.1
          ipv6: 'fd6e:a81b:704f:1211::1'
        socks5:
          port: \(c.port)
          address: 127.0.0.1
          udp: 'udp'
          username: '\(c.user)'
          password: '\(c.pass)'
        misc:
          task-stack-size: 20480
          tcp-buffer-size: 4096
          connect-timeout: 5000
          read-write-timeout: 60000
          log-file: stderr
          log-level: warn
        """
        Socks5Tunnel.run(withConfig: .string(content: yaml)) { [weak self] code in
            guard let self = self, !self.stopping else { return }
            self.log("tun2socks exited: \(code)")
            let err = TunnelError.tun2socks(code)
            AppGroup.defaults.set(err.localizedDescription, forKey: TunnelKeys.lastError)
            self.cancelTunnelWithError(err)
        }
    }

    // MARK: network settings

    private func makeSettings(_ c: Cfg) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        s.mtu = 1400

        let v4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route.default()]
        v4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0")
        ]
        s.ipv4Settings = v4

        // Забираем и IPv6, иначе v6-трафик утечёт мимо туннеля
        let v6 = NEIPv6Settings(addresses: ["fd6e:a81b:704f:1211::1"], networkPrefixLengths: [64])
        v6.includedRoutes = [NEIPv6Route.default()]
        v6.excludedRoutes = [NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
                             NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10)]
        s.ipv6Settings = v6

        let dns = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        dns.matchDomains = [""]            // все домены резолвятся через туннельный DNS
        s.dnsSettings = dns
        return s
    }

    // MARK: смена сети

    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in self?.queue.async { self?.handle(path) } }
        m.start(queue: queue)
        monitor = m
    }

    private func handle(_ path: NWPath) {
        let ifs = [(NWInterface.InterfaceType.wifi, "w"), (.cellular, "c"), (.wiredEthernet, "e")]
            .filter { path.usesInterfaceType($0.0) }.map { $0.1 }.joined()
        let sig = "\(path.status)|\(ifs)"
        guard let prev = lastSignature else { lastSignature = sig; return }
        guard sig != prev else { return }
        lastSignature = sig
        log("path: \(sig)")

        restartWork?.cancel()
        if path.status != .satisfied { reasserting = true; return }   // ждём сеть
        let w = DispatchWorkItem { [weak self] in self?.restartXray() }
        restartWork = w
        queue.asyncAfter(deadline: .now() + 1, execute: w)           // debounce
    }

    // MARK: helpers

    private func fail(_ error: Error, _ completion: @escaping (Error?) -> Void) {
        log("FAIL: \(error.localizedDescription)")
        AppGroup.defaults.set(error.localizedDescription, forKey: TunnelKeys.lastError)
        completion(error)
    }

    private func log(_ s: String) { SharedLog.write(s) }
}
