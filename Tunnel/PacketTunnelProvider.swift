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
        let opts: TunnelOptions
        init?(_ p: [String: Any]?) {
            guard let p = p,
                  let j = p[TunnelKeys.xrayConfig] as? String,
                  let port = (p[TunnelKeys.socksPort] as? NSNumber)?.intValue,
                  let u = p[TunnelKeys.socksUser] as? String,
                  let pw = p[TunnelKeys.socksPass] as? String,
                  let h = p[TunnelKeys.serverHost] as? String,
                  let sp = (p[TunnelKeys.serverPort] as? NSNumber)?.intValue else { return nil }
            json = j; self.port = port; user = u; pass = pw; host = h; serverPort = sp
            opts = TunnelOptions.from(json: p[TunnelKeys.options] as? String)
        }
    }

    private let queue = DispatchQueue(label: "eclipse.tunnel.q")
    private var cfg: Cfg?
    private var monitor: NWPathMonitor?
    private var lastSignature: String?
    private var restartWork: DispatchWorkItem?
    private var stopping = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        AppGroup.defaults.removeObject(forKey: TunnelKeys.lastError)
        stopping = false
        log("startTunnel, xray \(XraybridgeVersion())")

        let proto = protocolConfiguration as? NETunnelProviderProtocol
        guard let c = Cfg(proto?.providerConfiguration) else {
            return fail(TunnelError.badConfig, completionHandler)
        }
        cfg = c

        Task {
            do {
                guard await Pinger.ping(host: c.host, port: c.serverPort, timeout: 5) != nil else {
                    throw TunnelError.serverUnreachable(c.host)
                }
                try startXray()
                do { try await setTunnelNetworkSettings(makeSettings(c)) }
                catch { throw TunnelError.settings(error.localizedDescription) }
                startTun2Socks(c)
                startMonitor()
                log("tunnel up")
                completionHandler(nil)
            } catch {
                XraybridgeStop()
                fail(error, completionHandler)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("stopTunnel reason=\(reason.rawValue)")
        stopping = true
        restartWork?.cancel()
        monitor?.cancel(); monitor = nil
        Socks5Tunnel.quit()
        XraybridgeStop()
        completionHandler()
    }

    private func startXray() throws {
        guard let c = cfg else { throw TunnelError.badConfig }
        let dir = AppGroup.container.appendingPathComponent("xray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("xray memoryLimit=\(c.opts.memoryLimit) МБ")
        var nsErr: NSError?
        if !XraybridgeStart(c.json, dir.path, &nsErr) {
            throw TunnelError.xray(nsErr?.localizedDescription ?? "unknown")
        }
        log("xray started")
    }

    private func restartXray() {
        guard !stopping else { return }
        log("network changed → restart xray")
        reasserting = true
        XraybridgeStop()
        do { try startXray() }
        catch {
            AppGroup.defaults.set(Sanitizer.clean(error.localizedDescription), forKey: TunnelKeys.lastError)
            cancelTunnelWithError(error)
            return
        }
        reasserting = false
    }

    private func startTun2Socks(_ c: Cfg) {
        let yaml = """
        tunnel:
          mtu: \(c.opts.mtu)
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
            AppGroup.defaults.set(Sanitizer.clean(err.localizedDescription), forKey: TunnelKeys.lastError)
            self.cancelTunnelWithError(err)
        }
    }

    private func makeSettings(_ c: Cfg) -> NEPacketTunnelNetworkSettings {
        let s = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        s.mtu = NSNumber(value: c.opts.mtu)

        let v4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [NEIPv4Route.default()]
        v4.excludedRoutes = !c.opts.bypassLAN ? [] : [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0")
        ]
        s.ipv4Settings = v4

        let v6 = NEIPv6Settings(addresses: ["fd6e:a81b:704f:1211::1"], networkPrefixLengths: [64])
        v6.includedRoutes = [NEIPv6Route.default()]
        v6.excludedRoutes = !c.opts.bypassLAN ? [] : [
            NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
            NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10)
        ]
        s.ipv6Settings = v6

        let dns = NEDNSSettings(servers: c.opts.dns.isEmpty ? ["1.1.1.1", "1.0.0.1"] : c.opts.dns)
        dns.matchDomains = [""]
        s.dnsSettings = dns
        return s
    }

    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in self?.queue.async { self?.handle(path) } }
        m.start(queue: queue)
        monitor = m
    }

    private func handle(_ path: Network.NWPath) {
        let ifs = [(NWInterface.InterfaceType.wifi, "w"), (.cellular, "c"), (.wiredEthernet, "e")]
            .filter { path.usesInterfaceType($0.0) }.map { $0.1 }.joined()
        let sig = "\(path.status)|\(ifs)"
        guard let prev = lastSignature else { lastSignature = sig; return }
        guard sig != prev else { return }
        lastSignature = sig
        log("path: \(sig)")
        restartWork?.cancel()
        if path.status != .satisfied { reasserting = true; return }
        let w = DispatchWorkItem { [weak self] in self?.restartXray() }
        restartWork = w
        queue.asyncAfter(deadline: .now() + 1, execute: w)
    }

    private func fail(_ error: Error, _ completion: @escaping (Error?) -> Void) {
        log("FAIL: \(error.localizedDescription)")
        AppGroup.defaults.set(Sanitizer.clean(error.localizedDescription), forKey: TunnelKeys.lastError)
        completion(error)
    }

    private func log(_ s: String) { SharedLog.write(s) }
}
