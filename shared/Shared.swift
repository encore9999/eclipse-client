import Foundation
import Network

enum AppGroup {
    static let id = "group.com.example.vpntest"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
    }
    static var available: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil
    }
    static var xrayLogPath: String { container.appendingPathComponent("xray-error.log").path }
}

enum TunnelKeys {
    static let xrayConfig = "xrayConfig"
    static let socksPort = "socksPort"
    static let socksUser = "socksUser"
    static let socksPass = "socksPass"
    static let serverHost = "serverHost"
    static let serverPort = "serverPort"
    static let lastError = "tunnel.lastError"
    static let options = "options"
    static let core = "core"          // "xray" | "singbox"
    static let udpServer = "udpServer" // true для QUIC-протоколов (hysteria2, tuic)
}

struct TunnelOptions: Codable, Equatable {
    var dns: [String] = ["1.1.1.1", "1.0.0.1"]
    var mtu: Int = 1400
    var mux = false
    var fragment = false
    var sniffing = true
    var bypassLAN = true
    var directRules: [String] = []
    var memoryLimit: Int = 50

    var json: String {
        guard let d = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    static func from(json: String?) -> TunnelOptions {
        guard let j = json, let d = j.data(using: .utf8),
              let o = try? JSONDecoder().decode(TunnelOptions.self, from: d) else { return TunnelOptions() }
        return o
    }
}

enum Sanitizer {
    static func clean(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            with: "***",
            options: .regularExpression)
        out = out.replacingOccurrences(
            of: "(password|passwd|pass|auth|token|secret|key|uuid|id)=[^&\\s\"']+",
            with: "$1=***",
            options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(
            of: "(vless|vmess|trojan|ss|hysteria2|hy2|tuic)://[^\\s\"']+",
            with: "$1://***",
            options: [.regularExpression, .caseInsensitive])
        return out
    }
}

enum SharedLog {
    private static let q = DispatchQueue(label: "eclipse.sharedlog")
    private static var url: URL { AppGroup.container.appendingPathComponent("tunnel.log") }

    static func write(_ s: String) {
        let safe = Sanitizer.clean(s)
        q.async {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(safe)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                if h.offsetInFile > 512_000 { h.truncateFile(atOffset: 0) }
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
    static func read() -> String { (try? String(contentsOf: url)) ?? "" }
}

struct Server: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var proto: String
    var host: String
    var port: Int
    var link: String
    var transport: String?
    var security: String?

    var hy2Auth: String?
    var hy2Obfs: String?
    var hy2ObfsPassword: String?
    var hy2SNI: String?
    var hy2Insecure: Bool = false

    // TUIC v5 (все поля опциональны, чтобы не ломать декодирование уже сохранённых серверов)
    var tuicUUID: String?
    var tuicPassword: String?
    var tuicCongestion: String?
    var tuicUDPMode: String?
    var tuicSNI: String?
    var tuicALPN: String?
    var tuicInsecure: Bool?

    /// QUIC-протоколы слушают UDP — TCP-проверка порта для них бессмысленна.
    var isUDPBased: Bool { proto == "hysteria2" || proto == "tuic" }
    /// Ядро, которое умеет этот протокол.
    var core: String { proto == "tuic" ? "singbox" : "xray" }

    var protocolLabel: String {
        if proto == "hysteria2" { return "HYSTERIA 2" }
        if proto == "tuic" { return "TUIC" }
        let base = proto == "ss" ? "SHADOWSOCKS" : proto.uppercased()
        if let s = security, !s.isEmpty, s != "none" { return "\(base) + \(s.uppercased())" }
        return base
    }
    var transportLabel: String? {
        guard let t = transport, !t.isEmpty else { return nil }
        return t.uppercased()
    }
    var securityLabel: String? {
        guard let s = security, !s.isEmpty else { return nil }
        return s.uppercased()
    }
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
        case "hysteria2", "hy2": return parseHysteria2(s, proto: "hysteria2")
        case "tuic": return parseTUIC(s)
        default: return nil
        }
    }

    static func parseSubscription(_ text: String) -> [Server] {
        var body = text
        if !body.contains("://") { body = decodeBase64(text) ?? "" }
        return body.components(separatedBy: CharacterSet.newlines).compactMap { parse($0) }
    }

    static func splitHostPort(_ hp: String) -> (String, Int)? {
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

    static func parseQuery(_ qs: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in qs.components(separatedBy: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let k = String(pair[..<eq])
            let v = String(pair[pair.index(after: eq)...])
            result[k] = v.removingPercentEncoding ?? v
        }
        return result
    }

    static func splitFragment(_ s: String) -> (String, String) {
        guard let h = s.firstIndex(of: "#") else { return (s, "") }
        let raw = String(s[s.index(after: h)...])
        return (String(s[..<h]), raw.removingPercentEncoding ?? raw)
    }

    private static func parseURLStyle(_ s: String, proto: String) -> Server? {
        let (body, name) = splitFragment(s)
        guard let sch = body.range(of: "://") else { return nil }
        var rest = String(body[sch.upperBound...])
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            query = parseQuery(String(rest[rest.index(after: q)...]))
            rest = String(rest[..<q])
        }
        if let sl = rest.firstIndex(of: "/") { rest = String(rest[..<sl]) }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let hp = String(rest[rest.index(after: at)...])
        guard let (host, port) = splitHostPort(hp) else { return nil }
        let transport = (query["type"] ?? "tcp").lowercased()
        let security = (query["security"] ?? (proto == "trojan" ? "tls" : "none")).lowercased()
        return Server(name: name.isEmpty ? host : name, proto: proto, host: host, port: port, link: s,
                      transport: transport.isEmpty ? "tcp" : transport, security: security)
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
        let net = ((obj["net"] as? String) ?? "tcp").lowercased()
        let tls = ((obj["tls"] as? String) ?? "").lowercased()
        return Server(name: name.isEmpty ? host : name, proto: "vmess", host: host, port: port, link: s,
                      transport: net.isEmpty ? "tcp" : net, security: tls == "tls" ? "tls" : "none")
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
        return Server(name: name.isEmpty ? host : name, proto: "ss", host: host, port: port, link: s,
                      transport: "tcp", security: nil)
    }


    /// tuic://UUID:PASSWORD@host:port?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=example.com&allow_insecure=1#name
    private static func parseTUIC(_ s: String) -> Server? {
        let (body, name) = splitFragment(s)
        guard let sch = body.range(of: "://") else { return nil }
        var rest = String(body[sch.upperBound...])
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            query = parseQuery(String(rest[rest.index(after: q)...]))
            rest = String(rest[..<q])
        }
        if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let userInfo = String(rest[..<at])
        guard let (host, port) = splitHostPort(String(rest[rest.index(after: at)...])) else { return nil }
        // UUID не содержит ':', пароль может — делим по первому двоеточию
        let uuid: String, password: String
        if let c = userInfo.firstIndex(of: ":") {
            uuid = String(userInfo[..<c]).removingPercentEncoding ?? String(userInfo[..<c])
            let pw = String(userInfo[userInfo.index(after: c)...])
            password = pw.removingPercentEncoding ?? pw
        } else {
            uuid = userInfo.removingPercentEncoding ?? userInfo
            password = query["password"] ?? ""
        }
        guard !uuid.isEmpty else { return nil }
        func flag(_ k: String) -> Bool {
            guard let v = query[k]?.lowercased() else { return false }
            return v == "1" || v == "true"
        }
        var srv = Server(name: name.isEmpty ? host : name, proto: "tuic", host: host, port: port, link: s,
                         transport: "quic", security: "tls")
        srv.tuicUUID = uuid
        srv.tuicPassword = password
        srv.tuicCongestion = query["congestion_control"] ?? query["congestion-control"] ?? query["cc"]
        srv.tuicUDPMode = query["udp_relay_mode"] ?? query["udp-relay-mode"]
        srv.tuicSNI = query["sni"] ?? query["peer"]
        srv.tuicALPN = query["alpn"]
        srv.tuicInsecure = flag("allow_insecure") || flag("allowInsecure") || flag("insecure") || flag("skip-cert-verify")
        return srv
    }

    private static func parseHysteria2(_ s: String, proto: String) -> Server? {
        let (body, name) = splitFragment(s)
        guard let sch = body.range(of: "://") else { return nil }
        var rest = String(body[sch.upperBound...])
        var query: [String: String] = [:]
        if let q = rest.firstIndex(of: "?") {
            query = parseQuery(String(rest[rest.index(after: q)...]))
            rest = String(rest[..<q])
        }
        if rest.hasSuffix("/") { rest = String(rest.dropLast()) }
        var auth: String?
        var hostPortPart: String
        if let at = rest.lastIndex(of: "@") {
            auth = String(rest[..<at])
            hostPortPart = String(rest[rest.index(after: at)...])
        } else {
            hostPortPart = rest
        }
        guard let (host, port) = splitHostPort(hostPortPart) else { return nil }
        return Server(
            name: name.isEmpty ? host : name,
            proto: proto, host: host, port: port, link: s,
            transport: "hysteria2", security: "tls",
            hy2Auth: auth,
            hy2Obfs: query["obfs"],
            hy2ObfsPassword: query["obfs-password"],
            hy2SNI: query["sni"],
            hy2Insecure: query["insecure"] == "1" || query["insecure"]?.lowercased() == "true"
        )
    }
}

