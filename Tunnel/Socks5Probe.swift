import Foundation
import Network

/// Проверка, что трафик реально проходит через локальный SOCKS5 ядра:
/// SOCKS5 (user/pass) -> CONNECT cp.cloudflare.com:80 -> GET /generate_204 -> ждём "HTTP/".
enum Socks5Probe {
    struct Result { let ok: Bool; let text: String }

    private struct ProbeError: Error { let msg: String }

    static func check(port: Int, user: String, pass: String,
                      host: String = "cp.cloudflare.com", timeout: TimeInterval = 10) async -> Result {
        guard let p = NWEndpoint.Port(rawValue: UInt16(port)) else { return Result(ok: false, text: "плохой порт") }
        let conn = NWConnection(host: "127.0.0.1", port: p, using: .tcp)
        let start = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { conn.cancel() }
        defer { conn.cancel() }
        do {
            try await ready(conn)
            // 1. метод авторизации: user/pass
            try await send(conn, Data([5, 1, 2]))
            let m = try await recv(conn, 2)
            guard m.count == 2, m[0] == 5, m[1] == 2 else { throw ProbeError(msg: "SOCKS5: ядро не приняло авторизацию") }
            // 2. логин/пароль
            let u = Array(user.utf8), pw = Array(pass.utf8)
            try await send(conn, Data([1, UInt8(u.count)] + u + [UInt8(pw.count)] + pw))
            let a = try await recv(conn, 2)
            guard a.count == 2, a[1] == 0 else { throw ProbeError(msg: "SOCKS5: неверный логин/пароль") }
            // 3. CONNECT host:80
            let h = Array(host.utf8)
            try await send(conn, Data([5, 1, 0, 3, UInt8(h.count)] + h + [0, 80]))
            let r = try await recv(conn, 4)
            guard r.count == 4, r[0] == 5 else { throw ProbeError(msg: "SOCKS5: странный ответ на CONNECT") }
            guard r[1] == 0 else { throw ProbeError(msg: "ядро не смогло открыть соединение к \(host) (код \(r[1])) - сервер/протокол не работает") }
            switch r[3] {
            case 1: _ = try await recv(conn, 6)
            case 4: _ = try await recv(conn, 18)
            case 3:
                let l = try await recv(conn, 1)
                _ = try await recv(conn, Int(l[0]) + 2)
            default: break
            }
            // 4. HTTP
            let req = "GET /generate_204 HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            try await send(conn, Data(req.utf8))
            let resp = try await recv(conn, 12)
            let line = String(decoding: resp, as: UTF8.self)
            guard line.hasPrefix("HTTP/") else { throw ProbeError(msg: "ответ не HTTP") }
            let ms = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            return Result(ok: true, text: "трафик проходит, \(ms) мс (\(line.trimmingCharacters(in: .whitespacesAndNewlines)))")
        } catch let e as ProbeError {
            return Result(ok: false, text: e.msg)
        } catch {
            return Result(ok: false, text: "нет ответа через туннель за \(Int(timeout)) с (\(error.localizedDescription))")
        }
    }

    private static func ready(_ c: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let lock = NSLock(); var done = false
            c.stateUpdateHandler = { st in
                lock.lock(); let was = done
                switch st {
                case .ready: done = true
                case .failed(let e): done = true; lock.unlock(); if !was { k.resume(throwing: e) }; return
                case .cancelled: done = true; lock.unlock(); if !was { k.resume(throwing: ProbeError(msg: "время вышло")) }; return
                default: break
                }
                lock.unlock()
                if case .ready = st, !was { k.resume() }
            }
            c.start(queue: .global())
        }
    }

    private static func send(_ c: NWConnection, _ d: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            c.send(content: d, completion: .contentProcessed { e in
                if let e = e { k.resume(throwing: e) } else { k.resume() }
            })
        }
    }

    private static func recv(_ c: NWConnection, _ n: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
            c.receive(minimumIncompleteLength: n, maximumLength: n) { d, _, _, e in
                if let e = e { k.resume(throwing: e) }
                else if let d = d, !d.isEmpty { k.resume(returning: d) }
                else { k.resume(throwing: ProbeError(msg: "ядро закрыло соединение без ответа")) }
            }
        }
    }
}
