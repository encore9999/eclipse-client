import NetworkExtension
import Network
import Xray
import Tun2SocksKit

enum TunnelError: LocalizedError, CustomNSError {
    case badConfig(String), serverUnreachable(String), xray(String), settings(String), tun2socks(Int32)

    var errorDescription: String? {
        switch self {
        case .badConfig(let m): return "Некорректная конфигурация туннеля (\(m))"
        case .serverUnreachable(let h): return "Сервер недоступен: \(h)"
        case .xray(let m): return "Ошибка ядра: \(m)"
        case .settings(let m): return "Не удалось применить сетевые настройки: \(m)"
        case .tun2socks(let c): return "Туннель остановился (код \(c))"
        }
    }
    // Без этого iOS показывает "EclipseTunnel.TunnelError error 0" вместо текста.
    static var errorDomain: String { "Eclipse" }
    var errorCode: Int {
        switch self {
        case .badConfig: return 1
        case .serverUnreachable: return 2
        case .xray: return 3
        case .settings: return 4
        case .tun2socks: return 5
        }
    }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "Ошибка туннеля"] }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private struct Cfg {
        var json: String, port: Int, user: String, pass: String, host: String, serverPort: Int
        let opts: TunnelOptions
        var core: String, udp: Bool
        var serverID: String, serverName: String
        let autoSwitch: Bool
        let fallbacks: [FallbackProfile]

        mutating func adopt(_ f: FallbackProfile) {
            json = f.json; port = f.socksPort; user = f.socksUser; pass = f.socksPass
            host = f.host; serverPort = f.port; core = f.core; udp = f.udp
            serverID = f.id; serverName = f.name
        }
        static func missingKeys(_ p: [String: Any]?) -> String {
            guard let p = p else { return "providerConfiguration пуст" }
            let need = [TunnelKeys.xrayConfig, TunnelKeys.socksPort, TunnelKeys.socksUser,
                        TunnelKeys.socksPass, TunnelKeys.serverHost, TunnelKeys.serverPort]
            let miss = need.filter { p[$0] == nil }
            return miss.isEmpty ? "неверный тип полей" : "нет полей: " + miss.joined(separator: ", ")
        }
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
            core = (p[TunnelKeys.core] as? String) ?? "xray"
            udp = (p[TunnelKeys.udpServer] as? Bool) ?? false
            serverID = (p[TunnelKeys.serverID] as? String) ?? ""
            serverName = (p[TunnelKeys.serverName] as? String) ?? h
            autoSwitch = (p[TunnelKeys.autoSwitch] as? Bool) ?? false
            if let fj = p[TunnelKeys.fallbacks] as? String, let fd = fj.data(using: .utf8),
               let list = try? JSONDecoder().decode([FallbackProfile].self, from: fd) {
                fallbacks = list
            } else {
                fallbacks = []
            }
        }
    }

    private let queue = DispatchQueue(label: "eclipse.tunnel.q")
    private var cfg: Cfg?
    private var monitor: NWPathMonitor?
    private var lastSignature: String?
    private var restartWork: DispatchWorkItem?
    private var stopping = false
    private var restarting = false
    private var t2sRunning = false
    private let t2sGroup = DispatchGroup()
    private var healthTimer: DispatchSourceTimer?
    private var probing = false
    private var pathOK = true
    private var failStreak = 0
    private let failThreshold = 3

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        AppGroup.defaults.removeObject(forKey: TunnelKeys.lastError)
        stopping = false
        restarting = false
        let v = ProcessInfo.processInfo.operatingSystemVersion
        log("startTunnel: iOS \(v.majorVersion).\(v.minorVersion), appGroup=\(AppGroup.available ? "ok" : "НЕТ"), xray \(XraybridgeVersion())")

        let proto = protocolConfiguration as? NETunnelProviderProtocol
        guard let c = Cfg(proto?.providerConfiguration) else {
            return fail(TunnelError.badConfig(Cfg.missingKeys(proto?.providerConfiguration)), completionHandler)
        }
        cfg = c
        log("сервер \(c.host):\(c.serverPort), ядро=\(c.core), udp=\(c.udp), mtu=\(c.opts.mtu), dns=\(c.opts.dns.joined(separator: ","))\(c.opts.dohURL.map { " (DoH)" } ?? "")")
        log("автопереключение: \(c.autoSwitch ? "вкл, запасных серверов \(max(0, c.fallbacks.count - 1))" : "выкл")")

        Task {
            do {
                // Раньше недоступный по TCP сервер блокировал подключение. Теперь это только запись
                // в журнал: подключаемся в любом случае, а ядро само покажет реальную ошибку.
                if !c.udp {
                    let ms = await Pinger.ping(host: c.host, port: c.serverPort, timeout: 4)
                    log(ms.map { "TCP до сервера: \($0) мс" } ?? "TCP до сервера: нет ответа (подключаемся всё равно)")
                } else {
                    log("QUIC-сервер: TCP-проверка пропущена")
                }
                try startCore()
                do { try await setTunnelNetworkSettings(makeSettings(c)) }
                catch { throw TunnelError.settings(error.localizedDescription) }
                log("сетевые настройки применены")
                startTun2Socks(c)
                startMonitor()
                startHealthLoop()
                log("tunnel up")
                completionHandler(nil)
                scheduleHealthCheck(delay: 1.5)
            } catch {
                stopTun2Socks()
                XraybridgeStop()
                fail(error, completionHandler)
            }
        }
    }

    // MARK: связь с приложением (когда App Group недоступна, это единственный способ достать журнал)

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let cmd = String(data: messageData, encoding: .utf8) ?? ""
        switch cmd {
        case "logs":
            var out = SharedLog.memoryDump()
            let core = coreLogTail()
            if !core.isEmpty { out += "\n--- журнал ядра ---\n" + core }
            completionHandler?(out.data(using: .utf8))
        case "active":
            let c = cfg
            completionHandler?("\(c?.serverID ?? "")|\(c?.serverName ?? "")".data(using: .utf8))
        case "health":
            guard let c = cfg else { completionHandler?("нет конфигурации".data(using: .utf8)); return }
            Task {
                let r = await Socks5Probe.check(port: c.port, user: c.user, pass: c.pass)
                self.log("health: \(r.text)")
                completionHandler?("\(r.ok ? "OK" : "FAIL"): \(r.text)".data(using: .utf8))
            }
        default:
            completionHandler?(nil)
        }
    }

    /// Проверка "проходит ли трафик через ядро": SOCKS5 -> cp.cloudflare.com:80.
    private func scheduleHealthCheck(delay: TimeInterval) {
        guard let c = cfg else { return }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if self.stopping { return }
            let r = await Socks5Probe.check(port: c.port, user: c.user, pass: c.pass)
            self.log("health: \(r.text)")
            if !r.ok {
                let t = self.coreLogTail(lines: 12)
                if !t.isEmpty { self.log("журнал ядра:\n" + t) }
            }
        }
    }

    // MARK: журнал ядра

    private var coreLogURL: URL {
        let dir = AppGroup.available ? AppGroup.container
            : (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
               ?? FileManager.default.temporaryDirectory)
        return dir.appendingPathComponent("core.log")
    }

    private func coreLogTail(lines: Int = 60) -> String {
        guard let t = try? String(contentsOf: coreLogURL), !t.isEmpty else { return "" }
        return t.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }

    /// Подставляет в конфиг ядра файл журнала (в песочнице расширения).
    private func withCoreLog(_ json: String, core: String) -> String {
        guard let d = json.data(using: .utf8),
              var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return json }
        var l = (o["log"] as? [String: Any]) ?? [:]
        if core == "singbox" { l["output"] = coreLogURL.path; l["level"] = "info" }
        else { l["error"] = coreLogURL.path; l["loglevel"] = "warning" }
        o["log"] = l
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return json }
        return String(decoding: out, as: UTF8.self)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("stopTunnel reason=\(reason.rawValue)")
        stopping = true
        restartWork?.cancel()
        monitor?.cancel(); monitor = nil
        // Ждём, пока tun2socks реально остановится: иначе быстрый повторный старт
        // (смена сервера) натыкается на ещё живой экземпляр и туннель больше не поднимается.
        healthTimer?.cancel(); healthTimer = nil
        stopTun2Socks()
        XraybridgeStop()
        completionHandler()
    }

    private func startCore() throws {
        guard let c = cfg else { throw TunnelError.badConfig("нет конфигурации") }
        let dir = AppGroup.container.appendingPathComponent("xray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XraybridgeSetMemoryLimit(Int32(c.opts.memoryLimit))
        log("core=\(c.core) memoryLimit=\(c.opts.memoryLimit) МБ")
        try? FileManager.default.removeItem(at: coreLogURL)
        let json = withCoreLog(c.json, core: c.core)
        var nsErr: NSError?
        let ok = c.core == "singbox"
            ? XraybridgeStartSingbox(json, dir.path, &nsErr)
            : XraybridgeStart(json, dir.path, &nsErr)
        if !ok { throw TunnelError.xray(nsErr?.localizedDescription ?? "unknown") }
        log("core started")
    }

    private func stopTun2Socks() {
        guard t2sRunning else { return }
        Socks5Tunnel.quit()
        _ = t2sGroup.wait(timeout: .now() + 2)
        t2sRunning = false
    }

    /// Смена сети: перезапускаем ядро И tun2socks. Раньше перезапускалось только ядро,
    /// и UDP-сессии tun2socks (DNS, QUIC) оставались мёртвыми - интернет "пропадал".
    private func restartStack() {
        guard !stopping, !restarting, let c = cfg else { return }
        log("network changed → restart core + tun2socks")
        failStreak = 0
        reasserting = true
        restarting = true
        stopTun2Socks()
        XraybridgeStop()
        do {
            try startCore()
            startTun2Socks(c)
        } catch {
            restarting = false
            AppGroup.defaults.set(Sanitizer.clean(error.localizedDescription), forKey: TunnelKeys.lastError)
            cancelTunnelWithError(error is TunnelError ? error : TunnelError.xray(error.localizedDescription))
            return
        }
        restarting = false
        reasserting = false
        scheduleHealthCheck(delay: 2)
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
        t2sRunning = true
        t2sGroup.enter()
        Socks5Tunnel.run(withConfig: .string(content: yaml)) { [weak self] code in
            self?.t2sGroup.leave()
            guard let self = self, !self.stopping, !self.restarting else { return }
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

        let ips = c.opts.dns.isEmpty ? ["1.1.1.1", "1.0.0.1"] : c.opts.dns
        if let u = c.opts.dohURL, let url = URL(string: u), url.scheme?.lowercased() == "https" {
            // DNS поверх HTTPS: запросы системы шифруются и идут через туннель
            let doh = NEDNSOverHTTPSSettings(servers: ips)
            doh.serverURL = url
            doh.matchDomains = [""]
            s.dnsSettings = doh
        } else {
            let dns = NEDNSSettings(servers: ips)
            dns.matchDomains = [""]
            s.dnsSettings = dns
        }
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
        pathOK = path.status == .satisfied
        let sig = "\(path.status)|\(ifs)"
        guard let prev = lastSignature else { lastSignature = sig; return }
        guard sig != prev else { return }
        lastSignature = sig
        log("path: \(sig)")
        restartWork?.cancel()
        if path.status != .satisfied { reasserting = true; return }
        let w = DispatchWorkItem { [weak self] in self?.restartStack() }
        restartWork = w
        queue.asyncAfter(deadline: .now() + 1, execute: w)
    }

    // MARK: автопереключение

    /// Раз в 15 секунд проверяем, что трафик реально идёт. После 3 провалов подряд (~45 с)
    /// переходим на следующий сервер подписки - даже если приложение свёрнуто.
    private func startHealthLoop() {
        healthTimer?.cancel()
        failStreak = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 15)
        t.setEventHandler { [weak self] in self?.healthTick() }
        t.resume()
        healthTimer = t
    }

    private func healthTick() {
        guard !stopping, !restarting, !probing, pathOK, let c = cfg, c.autoSwitch, c.fallbacks.count > 1 else { return }
        probing = true
        Task { [weak self] in
            let r = await Socks5Probe.check(port: c.port, user: c.user, pass: c.pass, timeout: 6)
            guard let self = self else { return }
            self.queue.async {
                self.probing = false
                // за время проверки конфиг мог смениться (смена сети, переключение) - тогда результат устарел
                guard !self.stopping, !self.restarting, self.cfg?.serverID == c.serverID else { return }
                if r.ok {
                    if self.failStreak > 0 { self.log("health: связь восстановилась") }
                    self.failStreak = 0
                    return
                }
                self.failStreak += 1
                self.log("health: сбой \(self.failStreak)/\(self.failThreshold) - \(r.text)")
                if self.failStreak >= self.failThreshold {
                    self.failStreak = 0
                    Task { await self.switchToNextServer(reason: r.text) }
                }
            }
        }
    }

    /// Перебирает запасные серверы по кругу и останавливается на первом, через который проходит трафик.
    private func switchToNextServer(reason: String) async {
        guard !stopping, !restarting, let original = cfg else { return }
        let pool = original.fallbacks
        guard original.autoSwitch, pool.count > 1 else { return }
        restarting = true
        reasserting = true
        log("автопереключение: \(original.serverName) не работает (\(reason)), ищем замену")
        stopTun2Socks()
        XraybridgeStop()

        var idx = pool.firstIndex { $0.id == original.serverID } ?? -1
        for _ in 0..<(pool.count - 1) {
            idx = (idx + 1) % pool.count
            let f = pool[idx]
            if f.id == original.serverID { continue }
            var next = original
            next.adopt(f)
            cfg = next
            do {
                try startCore()
                startTun2Socks(next)
            } catch {
                log("автопереключение: \(f.name) не запустился (\(error.localizedDescription))")
                stopTun2Socks(); XraybridgeStop()
                continue
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let r = await Socks5Probe.check(port: next.port, user: next.user, pass: next.pass, timeout: 6)
            if r.ok {
                log("автопереключение: теперь \(f.name) - \(r.text)")
                AppGroup.defaults.set(f.id, forKey: "activeServerID")
                restarting = false
                reasserting = false
                return
            }
            log("автопереключение: \(f.name) тоже не отвечает (\(r.text))")
            stopTun2Socks(); XraybridgeStop()
        }

        // Ничего не подошло - возвращаем выбранный пользователем сервер, пусть ядро пробует дальше.
        log("автопереключение: рабочих серверов не нашлось, возвращаем \(original.serverName)")
        cfg = original
        do { try startCore(); startTun2Socks(original) }
        catch {
            restarting = false
            cancelTunnelWithError(error is TunnelError ? error : TunnelError.xray(error.localizedDescription))
            return
        }
        restarting = false
        reasserting = false
    }

    private func fail(_ error: Error, _ completion: @escaping (Error?) -> Void) {
        log("FAIL: \(error.localizedDescription)")
        let t = coreLogTail(lines: 10)
        if !t.isEmpty { log("журнал ядра:\n" + t) }
        AppGroup.defaults.set(Sanitizer.clean(error.localizedDescription), forKey: TunnelKeys.lastError)
        completion(error is TunnelError ? error : TunnelError.xray(error.localizedDescription))
    }

    private func log(_ s: String) { SharedLog.write(s) }
}
