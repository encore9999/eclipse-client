import Foundation
import Network
import Darwin

enum PingProtocol: String, Codable, CaseIterable, Identifiable {
    case tcp, httpGet, httpHead, icmp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tcp: return "TCP"
        case .httpGet: return "HTTP GET"
        case .httpHead: return "HTTP HEAD"
        case .icmp: return "ICMP"
        }
    }
    var subtitle: String {
        switch self {
        case .tcp: return "Рекомендуется - самый быстрый"
        case .httpGet: return "GET-запрос, время до первого ответа сервера"
        case .httpHead: return "HEAD-запрос, время до первого ответа сервера"
        case .icmp: return "ICMP echo (часть серверов его блокирует)"
        }
    }
}

enum Pinger {
    private final class Once {
        private let lock = NSLock()
        private var fired = false
        func run(_ f: () -> Void) {
            lock.lock(); let already = fired; fired = true; lock.unlock()
            if !already { f() }
        }
    }

    /// Универсальный пинг. Возвращает миллисекунды или nil, если сервер не ответил.
    /// - udpBased: сервер на QUIC (Hysteria2 / TUIC). Его TCP-порт обычно закрыт,
    ///   поэтому любой режим для него сводится к ICMP.
    /// - useTLS: для HTTP-режимов - ходить по https (true) или http (false).
    static func ping(host: String, port: Int,
                     mode: PingProtocol = .tcp,
                     udpBased: Bool = false,
                     useTLS: Bool? = nil,
                     timeout: TimeInterval = 3) async -> Int? {
        if udpBased { return await icmp(host: host, timeout: timeout) }
        switch mode {
        case .tcp:      return await tcp(host: host, port: port, timeout: timeout)
        case .icmp:     return await icmp(host: host, timeout: timeout)
        case .httpGet:  return await http(host: host, port: port, method: "GET",
                                          tls: useTLS ?? defaultTLS(port), timeout: timeout)
        case .httpHead: return await http(host: host, port: port, method: "HEAD",
                                          tls: useTLS ?? defaultTLS(port), timeout: timeout)
        }
    }

    private static func defaultTLS(_ port: Int) -> Bool {
        [443, 2053, 2083, 2087, 2096, 4443, 8443, 9443].contains(port)
    }

    // MARK: TCP

    private static func tcp(host: String, port: Int, timeout: TimeInterval) async -> Int? {
        guard port > 0, port <= 65535,
              let p = Network.NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let conn = NWConnection(host: Network.NWEndpoint.Host(host), port: p, using: .tcp)
            let once = Once()
            let start = DispatchTime.now().uptimeNanoseconds
            @Sendable func finish(_ v: Int?) {
                once.run { conn.cancel(); cont.resume(returning: v) }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
                case .failed: finish(nil)
                case .waiting(let err):
                    if case .posix(let code) = err, code == .ECONNREFUSED { finish(nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: HTTP GET / HEAD
    // Сырой HTTP/1.1 поверх NWConnection: без ATS-ограничений, без редиректов,
    // сертификат не проверяется (мы меряем время ответа, а не доверие к серверу).
    // Засчитывается любой ответ, начинающийся с "HTTP/" (200, 301, 400, 404 - неважно).

    private static func http(host: String, port: Int, method: String,
                             tls: Bool, timeout: TimeInterval) async -> Int? {
        guard port > 0, port <= 65535,
              let p = Network.NWEndpoint.Port(rawValue: UInt16(port)) else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let params: NWParameters
            if tls {
                let t = NWProtocolTLS.Options()
                sec_protocol_options_set_verify_block(t.securityProtocolOptions,
                                                      { _, _, complete in complete(true) }, .global())
                params = NWParameters(tls: t, tcp: NWProtocolTCP.Options())
            } else {
                params = .tcp
            }
            let conn = NWConnection(host: Network.NWEndpoint.Host(host), port: p, using: params)
            let once = Once()
            let start = DispatchTime.now().uptimeNanoseconds
            @Sendable func finish(_ v: Int?) {
                once.run { conn.cancel(); cont.resume(returning: v) }
            }
            let hostHeader = host.contains(":") ? "[\(host)]" : host
            let request = "\(method) / HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: Eclipse\r\nAccept: */*\r\nConnection: close\r\n\r\n"
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { err in
                        if err != nil { finish(nil) }
                    })
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, err in
                        if let d = data, d.starts(with: Data("HTTP/".utf8)) {
                            finish(max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)))
                        } else {
                            finish(nil)
                        }
                    }
                case .failed: finish(nil)
                case .waiting(let err):
                    if case .posix(let code) = err, code == .ECONNREFUSED { finish(nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    // MARK: ICMP
    // iOS разрешает ICMP echo без root через SOCK_DGRAM + IPPROTO_ICMP / IPPROTO_ICMPV6.

    private static func icmp(host: String, timeout: TimeInterval) async -> Int? {
        await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: icmpSync(host: host, timeout: timeout))
            }
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]); i += 2 }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    private static func icmpSync(host: String, timeout: TimeInterval) -> Int? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }

        var chosen = first
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let c = cursor {
            if c.pointee.ai_family == AF_INET { chosen = c; break }
            cursor = c.pointee.ai_next
        }
        let isV6 = chosen.pointee.ai_family == AF_INET6
        guard isV6 || chosen.pointee.ai_family == AF_INET else { return nil }

        let fd = socket(chosen.pointee.ai_family, SOCK_DGRAM, isV6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let ident = UInt16.random(in: 1...UInt16.max)
        let seq = UInt16.random(in: 1...UInt16.max)
        var pkt = [UInt8](repeating: 0, count: 16)
        pkt[0] = isV6 ? 128 : 8              // echo request
        pkt[4] = UInt8(ident >> 8); pkt[5] = UInt8(ident & 0xFF)
        pkt[6] = UInt8(seq >> 8);   pkt[7] = UInt8(seq & 0xFF)
        for i in 8..<16 { pkt[i] = UInt8(i) }
        if !isV6 {                            // для ICMPv6 контрольную сумму считает ядро
            let cs = checksum(pkt)
            pkt[2] = UInt8(cs >> 8); pkt[3] = UInt8(cs & 0xFF)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = pkt.withUnsafeBytes { raw in
            sendto(fd, raw.baseAddress, raw.count, 0, chosen.pointee.ai_addr, chosen.pointee.ai_addrlen)
        }
        guard sent == pkt.count else { return nil }

        let deadline = start + UInt64(timeout * 1_000_000_000)
        var buf = [UInt8](repeating: 0, count: 1500)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, (deadline - now) / 1_000_000))
            let r = poll(&pfd, 1, waitMs)
            if r <= 0 { return nil }
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            var off = 0
            if !isV6, n >= 20, (buf[0] >> 4) == 4 { off = Int(buf[0] & 0x0F) * 4 }   // в ответе есть IP-заголовок
            guard n >= off + 8 else { continue }
            let type = buf[off]
            let rseq = UInt16(buf[off + 6]) << 8 | UInt16(buf[off + 7])
            if type == (isV6 ? 129 : 0), rseq == seq {
                return max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000))
            }
        }
    }
}
