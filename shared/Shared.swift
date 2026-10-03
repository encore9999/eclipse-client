import Foundation
import Network

// Этот файл компилируется и в приложение, и в расширение.
// Не импортируйте сюда SwiftUI/UIKit.

// MARK: - App Group / ключи

enum AppGroup {
    static let id = "group.com.example.vpntest"   // должен совпадать с project.yml
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
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
}

enum SharedLog {
    private static let q = DispatchQueue(label: "eclipse.sharedlog")
    private static var url: URL { AppGroup.container.appendingPathComponent("tunnel.log") }

    static func write(_ s: String) {
        q.async {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
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

// MARK: - Models

struct Server: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var proto: String
    var host: String
    var port: Int
    var link: String
    var transport: String?
    var security: String?

    // "VLESS + REALITY", "TROJAN + TLS", "VMESS"
    var protocolLabel: String {
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

    // internal (не private): используются XrayConfigBuilder
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
}

// MARK: - TCP-пинг

enum Pinger {
    private final class Once {
        private let lock = NSLock()
        private var fired = false
        func run(_ f: () -> Void) {
            lock.lock()
            let already = fired
            fired = true
            lock.unlock()
            if !already { f() }
        }
    }

    static func ping(host: String, port: Int, timeout: TimeInterval = 3) async -> Int? {
        guard port > 0, port <= 65535,
              let p = Network.NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let conn = NWConnection(host: Network.NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            let start = DispatchTime.now().uptimeNanoseconds
            func finish(_ v: Int?) {
                once.run {
                    conn.cancel()
                    cont.resume(returning: v)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                    finish(ms)
                case .failed:
                    finish(nil)
                default:
                    break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}
