import Foundation

/// Конфиг для sing-box (используется только для TUIC).
/// sing-box поднимает локальный SOCKS5 с паролем - ровно как Xray, поэтому
/// Tun2SocksKit и остальная часть туннеля работают без изменений.
enum SingboxConfigBuilder {
    static func build(for server: Server, options: TunnelOptions, socksPort: Int) throws -> XrayProfile {
        guard server.proto == "tuic",
              let uuid = server.tuicUUID, !uuid.isEmpty else { throw XrayConfigError.invalidLink }

        let user = XrayConfigBuilder.token(8), pass = XrayConfigBuilder.token(16)

        var tls: [String: Any] = ["enabled": true]
        let sni = (server.tuicSNI ?? "").trimmingCharacters(in: .whitespaces)
        if !sni.isEmpty { tls["server_name"] = sni }
        else if !XrayConfigBuilder.isIP(server.host) { tls["server_name"] = server.host }
        if server.tuicInsecure == true { tls["insecure"] = true }
        let alpn = (server.tuicALPN ?? "h3")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        tls["alpn"] = alpn.isEmpty ? ["h3"] : alpn

        let ccAllowed = ["cubic", "new_reno", "bbr"]
        let cc = (server.tuicCongestion ?? "").lowercased()
        var tuic: [String: Any] = [
            "type": "tuic", "tag": "proxy",
            "server": server.host, "server_port": server.port,
            "uuid": uuid, "password": server.tuicPassword ?? "",
            "congestion_control": ccAllowed.contains(cc) ? cc : "bbr",
            "zero_rtt_handshake": false,
            "heartbeat": "10s",          // держит NAT-маппинг UDP на мобильной сети
            "tls": tls
        ]
        let mode = (server.tuicUDPMode ?? "").lowercased()
        if mode == "native" || mode == "quic" { tuic["udp_relay_mode"] = mode }

        let dnsIP = options.dns.first(where: { XrayConfigBuilder.isIP($0) }) ?? "1.1.1.1"

        var route: [String: Any] = ["final": "proxy", "default_domain_resolver": "dns-bootstrap"]
        let rules = directRules(options.directRules)
        if !rules.isEmpty { route["rules"] = rules }

        let cfg: [String: Any] = [
            "log": ["level": "warn", "timestamp": false],
            "dns": ["servers": [["type": "udp", "tag": "dns-bootstrap", "server": dnsIP]]],
            "inbounds": [[
                "type": "socks", "tag": "socks-in",
                "listen": "127.0.0.1", "listen_port": socksPort,
                "users": [["username": user, "password": pass]]
            ]],
            "outbounds": [tuic, ["type": "direct", "tag": "direct"]],
            "route": route
        ]
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])
        return XrayProfile(json: String(decoding: data, as: UTF8.self),
                           socksPort: socksPort, socksUser: user, socksPass: pass, core: "singbox")
    }

    /// Прямые правила (домены / IP / geo) -> route.rules sing-box.
    private static func directRules(_ raw: [String]) -> [[String: Any]] {
        var suffix: [String] = [], full: [String] = [], keyword: [String] = [], regex: [String] = []
        var cidr: [String] = []
        func add(domainRule r: String) {
            let low = r.lowercased()
            if low.hasPrefix("domain:") { suffix.append(String(r.dropFirst(7))) }
            else if low.hasPrefix("full:") { full.append(String(r.dropFirst(5))) }
            else if low.hasPrefix("keyword:") { keyword.append(String(r.dropFirst(8))) }
            else if low.hasPrefix("regexp:") { regex.append(String(r.dropFirst(7))) }
            else { suffix.append(low) }
        }
        for line in raw {
            let r = line.trimmingCharacters(in: .whitespaces)
            let low = r.lowercased()
            if r.isEmpty || r.hasPrefix("#") { continue }
            if low.hasPrefix("geoip:") || low.hasPrefix("geosite:") {
                let (d, i) = XrayConfigBuilder.expandGeo(r)
                d.forEach { add(domainRule: $0) }
                cidr.append(contentsOf: i)
            } else if ["domain:", "full:", "keyword:", "regexp:"].contains(where: { low.hasPrefix($0) }) {
                add(domainRule: r)
            } else if XrayConfigBuilder.isIP(r) {
                cidr.append(r)
            } else {
                suffix.append(low)
            }
        }
        var out: [[String: Any]] = []
        func rule(_ key: String, _ v: [String]) {
            if !v.isEmpty { out.append([key: v, "action": "route", "outbound": "direct"]) }
        }
        rule("domain_suffix", suffix); rule("domain", full)
        rule("domain_keyword", keyword); rule("domain_regex", regex); rule("ip_cidr", cidr)
        return out
    }
}
