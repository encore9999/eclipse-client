import Foundation

struct XrayProfile {
    let json: String
    let socksPort: Int
    let socksUser: String
    let socksPass: String
}

enum XrayConfigError: LocalizedError {
    case invalidLink
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalidLink: return "Некорректная ссылка сервера"
        case .unsupported(let s): return "Не поддерживается: \(s)"
        }
    }
}

enum XrayConfigBuilder {
    static func build(for server: Server, options: TunnelOptions = TunnelOptions(),
                      logPath: String?, socksPort: Int = 10808) throws -> XrayProfile {
        let user = token(8), pass = token(16)
        var outbound = try makeOutbound(server: server)
        outbound["tag"] = "proxy"

        let muxOK = ["vless", "vmess", "trojan"].contains(server.proto) && !server.link.contains("flow=")
        if options.mux && muxOK { outbound["mux"] = ["enabled": true, "concurrency": 8] }

        var extra: [[String: Any]] = [["tag": "direct", "protocol": "freedom"]]
        if options.fragment {
            var ss = (outbound["streamSettings"] as? [String: Any]) ?? [:]
            ss["sockopt"] = ["dialerProxy": "fragment"]
            outbound["streamSettings"] = ss
            extra.append(["tag": "fragment", "protocol": "freedom",
                          "settings": ["fragment": ["packets": "tlshello",
                                                    "length": "100-200", "interval": "10-20"]]])
        }

        var log: [String: Any] = ["loglevel": "warning", "access": "none"]
        if let p = logPath { log["error"] = p }

        let dnsServers = options.dns.isEmpty ? ["1.1.1.1", "1.0.0.1"] : options.dns
        var sniffing: [String: Any] = ["enabled": options.sniffing]
        if options.sniffing {
            sniffing["destOverride"] = ["http", "tls", "quic"]
            sniffing["routeOnly"] = true
        }

        var cfg: [String: Any] = [
            "log": log,
            "dns": ["servers": dnsServers, "queryStrategy": "UseIP"],
            "inbounds": [[
                "tag": "socks-in", "listen": "127.0.0.1", "port": socksPort, "protocol": "socks",
                "settings": ["auth": "password", "accounts": [["user": user, "pass": pass]],
                             "udp": true, "ip": "127.0.0.1"],
                "sniffing": sniffing
            ]],
            "outbounds": [outbound] + extra
        ]
        if let r = routing(options.directRules) { cfg["routing"] = r }

        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])
        return XrayProfile(json: String(decoding: data, as: UTF8.self),
                           socksPort: socksPort, socksUser: user, socksPass: pass)
    }

    private static func routing(_ raw: [String]) -> [String: Any]? {
        var domains: [String] = [], ips: [String] = []
        let known = ["domain:", "full:", "keyword:", "regexp:"]
        for line in raw {
            let r = line.trimmingCharacters(in: .whitespaces)
            let low = r.lowercased()
            if r.isEmpty || r.hasPrefix("#") { continue }
            if low.hasPrefix("geoip:") || low.hasPrefix("geosite:") {
                let (gDomains, gIps) = expandGeo(r)
                domains.append(contentsOf: gDomains)
                ips.append(contentsOf: gIps)
                continue
            }
            if known.contains(where: { low.hasPrefix($0) }) { domains.append(r) }
            else if isIP(r) { ips.append(r) }
            else { domains.append("domain:" + low) }
        }
        var rules: [[String: Any]] = []
        if !domains.isEmpty { rules.append(["type": "field", "domain": domains, "outboundTag": "direct"]) }
        if !ips.isEmpty { rules.append(["type": "field", "ip": ips, "outboundTag": "direct"]) }
        return rules.isEmpty ? nil : ["domainStrategy": "AsIs", "rules": rules]
    }

    private static func expandGeo(_ rule: String) -> (domains: [String], ips: [String]) {
        let low = rule.lowercased()
        if low.hasPrefix("geoip:") {
            let code = String(rule.dropFirst("geoip:".count))
            return ([], GeoDat.cidrs(code: code, limit: 4000) ?? [])
        }
        if low.hasPrefix("geosite:") {
            let code = String(rule.dropFirst("geosite:".count))
            return (GeoDat.domains(code: code, limit: 2000) ?? [], [])
        }
        return ([], [])
    }

    private static func isIP(_ s: String) -> Bool {
        let base = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, base, &v4) == 1 || inet_pton(AF_INET6, base, &v6) == 1
    }

    private static func token(_ n: Int) -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(n))
    }

    private static func makeOutbound(server: Server) throws -> [String: Any] {
        switch server.proto {
        case "vless", "trojan", "vmess", "ss":
            return try makeStandardOutbound(link: server.link)
        case "hysteria2":
            return makeHysteria2Outbound(server: server)
        default:
            throw XrayConfigError.unsupported(server.proto)
        }
    }

    private static func makeStandardOutbound(link: String) throws -> [String: Any] {
        let scheme = link.components(separatedBy: "://").first?.lowercased() ?? ""
        switch scheme {
        case "vless":  return try vless(link)
        case "trojan": return try trojan(link)
        case "vmess":  return try vmess(link)
        case "ss":     return try shadowsocks(link)
        default: throw XrayConfigError.unsupported(scheme)
        }
    }

    // Hysteria 2 — плоский outbound без кастомных streamSettings
    private static func makeHysteria2Outbound(server: Server) -> [String: Any] {
        var settings: [String: Any] = [
            "version": 2,
            "address": server.host,
            "port": server.port
        ]
        if let auth = server.hy2Auth, !auth.isEmpty { settings["auth"] = auth }
        if let sni = server.hy2SNI, !sni.isEmpty { settings["sni"] = sni }
        if server.hy2Insecure { settings["insecure"] = true }
        if let obfs = server.hy2Obfs, !obfs.isEmpty {
            var mask: [String: Any] = ["type": obfs]
            if let pw = server.hy2ObfsPassword, !pw.isEmpty { mask["password"] = pw }
            settings["obfs"] = mask
        }
        return ["protocol": "hysteria", "settings": settings]
    }

    private struct Parts { var host: String; var port: Int; var userInfo: String; var query: [String: String] }

    private static func parts(_ link: String) throws -> Parts {
        let (body, _) = LinkParser.splitFragment(link)
        guard let sch = body.range(of: "://") else { throw XrayConfigError.invalidLink }
        var rest = String(body[sch.upperBound...])
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            query = LinkParser.parseQuery(String(rest[rest.index(after: q)...]))
            rest = String(rest[..<q])
        }
        if let sl = rest.firstIndex(of: "/") { rest = String(rest[..<sl]) }
        guard let at = rest.lastIndex(of: "@"),
              let (host, port) = LinkParser.splitHostPort(String(rest[rest.index(after: at)...]))
        else { throw XrayConfigError.invalidLink }
        let ui = String(rest[..<at])
        return Parts(host: host, port: port, userInfo: ui.removingPercentEncoding ?? ui, query: query)
    }

    private static func vless(_ link: String) throws -> [String: Any] {
        let p = try parts(link), q = p.query
        var user: [String: Any] = ["id": p.userInfo, "encryption": q["encryption"] ?? "none"]
        if let f = q["flow"], !f.isEmpty { user["flow"] = f }
        return [
            "protocol": "vless",
            "settings": ["vnext": [["address": p.host, "port": p.port, "users": [user]]]],
            "streamSettings": try stream(network: q["type"] ?? "tcp", security: q["security"] ?? "none",
                                         q: q, fallbackHost: p.host)
        ]
    }

    private static func trojan(_ link: String) throws -> [String: Any] {
        let p = try parts(link), q = p.query
        return [
            "protocol": "trojan",
            "settings": ["servers": [["address": p.host, "port": p.port, "password": p.userInfo]]],
            "streamSettings": try stream(network: q["type"] ?? "tcp", security: q["security"] ?? "tls",
                                         q: q, fallbackHost: p.host)
        ]
    }

    private static func vmess(_ link: String) throws -> [String: Any] {
        let payload = String(link.dropFirst("vmess://".count))
        guard let json = LinkParser.decodeBase64(payload),
              let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let host = o["add"] as? String,
              let id = o["id"] as? String else { throw XrayConfigError.invalidLink }
        let port = (o["port"] as? Int) ?? Int((o["port"] as? String) ?? "") ?? 0
        let aid = (o["aid"] as? Int) ?? Int((o["aid"] as? String) ?? "") ?? 0
        let path = (o["path"] as? String) ?? ""
        let q: [String: String] = [
            "path": path, "serviceName": path,
            "host": (o["host"] as? String) ?? "",
            "sni": (o["sni"] as? String) ?? "",
            "alpn": (o["alpn"] as? String) ?? "",
            "fp": (o["fp"] as? String) ?? ""
        ]
        let tls = ((o["tls"] as? String) ?? "").lowercased() == "tls" ? "tls" : "none"
        return [
            "protocol": "vmess",
            "settings": ["vnext": [["address": host, "port": port,
                                    "users": [["id": id, "alterId": aid,
                                               "security": (o["scy"] as? String) ?? "auto"]]]]],
            "streamSettings": try stream(network: (o["net"] as? String) ?? "tcp", security: tls,
                                         q: q, fallbackHost: host)
        ]
    }

    private static func shadowsocks(_ link: String) throws -> [String: Any] {
        let (b0, _) = LinkParser.splitFragment(link)
        var body = String(b0.dropFirst("ss://".count))
        if let q = body.firstIndex(of: "?") { body = String(body[..<q]) }
        if let s = body.firstIndex(of: "/") { body = String(body[..<s]) }
        var cred: String, hostPort: String
        if let at = body.lastIndex(of: "@") {
            let ui = String(body[..<at])
            hostPort = String(body[body.index(after: at)...])
            cred = LinkParser.decodeBase64(ui) ?? (ui.removingPercentEncoding ?? ui)
        } else if let dec = LinkParser.decodeBase64(body), let at = dec.lastIndex(of: "@") {
            cred = String(dec[..<at])
            hostPort = String(dec[dec.index(after: at)...])
        } else { throw XrayConfigError.invalidLink }
        guard let c = cred.firstIndex(of: ":"),
              let (host, port) = LinkParser.splitHostPort(hostPort) else { throw XrayConfigError.invalidLink }
        return [
            "protocol": "shadowsocks",
            "settings": ["servers": [["address": host, "port": port,
                                      "method": String(cred[..<c]),
                                      "password": String(cred[cred.index(after: c)...])]]]
        ]
    }

    private static func stream(network: String, security: String,
                               q: [String: String], fallbackHost: String) throws -> [String: Any] {
        var s: [String: Any] = [:]
        let host = q["host"] ?? ""
        switch network.lowercased() {
        case "tcp", "": s["network"] = "tcp"
        case "ws":
            s["network"] = "ws"
            var ws: [String: Any] = ["path": q["path"] ?? "/"]
            if !host.isEmpty { ws["headers"] = ["Host": host] }
            s["wsSettings"] = ws
        case "grpc":
            s["network"] = "grpc"
            s["grpcSettings"] = ["serviceName": q["serviceName"] ?? q["path"] ?? "",
                                 "multiMode": q["mode"] == "multi"]
        case "httpupgrade":
            s["network"] = "httpupgrade"
            s["httpupgradeSettings"] = ["path": q["path"] ?? "/", "host": host]
        case "xhttp", "splithttp":
            s["network"] = "xhttp"
            var x: [String: Any] = ["path": q["path"] ?? "/"]
            if !host.isEmpty { x["host"] = host }
            if let m = q["mode"], !m.isEmpty { x["mode"] = m }
            s["xhttpSettings"] = x
        case "h2", "http":
            s["network"] = "h2"
            s["httpSettings"] = ["path": q["path"] ?? "/", "host": host.isEmpty ? [] : [host]]
        case let other: throw XrayConfigError.unsupported("transport \(other)")
        }

        let sni = (q["sni"]?.isEmpty == false ? q["sni"] : nil) ?? q["peer"] ?? (host.isEmpty ? fallbackHost : host)
        switch security.lowercased() {
        case "tls":
            s["security"] = "tls"
            var t: [String: Any] = ["serverName": sni]
            if let fp = q["fp"], !fp.isEmpty { t["fingerprint"] = fp }
            if let a = q["alpn"], !a.isEmpty { t["alpn"] = a.components(separatedBy: ",") }
            if q["allowInsecure"] == "1" { t["allowInsecure"] = true }
            s["tlsSettings"] = t
        case "reality":
            guard let pbk = q["pbk"], !pbk.isEmpty else { throw XrayConfigError.unsupported("REALITY без pbk") }
            s["security"] = "reality"
            s["realitySettings"] = ["serverName": sni,
                                    "fingerprint": (q["fp"]?.isEmpty == false ? q["fp"]! : "chrome"),
                                    "publicKey": pbk, "shortId": q["sid"] ?? "", "spiderX": q["spx"] ?? ""]
        default: s["security"] = "none"
        }
        return s
    }
}
