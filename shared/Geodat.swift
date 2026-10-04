import Foundation

// Работа с geoip.dat / geosite.dat (формат v2ray, protobuf).
// Файл не загружается в Xray целиком: мы читаем его через mmap, достаём только нужные
// категории и подставляем их в маршруты как обычные правила. Так хватает памяти расширения.

enum GeoError: LocalizedError {
    case badURL, http(Int), tooSmall
    var errorDescription: String? {
        switch self {
        case .badURL: return "Некорректная ссылка на геоданные"
        case .http(let c): return "Сервер геоданных ответил кодом \(c)"
        case .tooSmall: return "Файл геоданных слишком мал"
        }
    }
}

enum GeoDat {
    // Общий каталог, если есть App Group; иначе собственная песочница процесса
    static var dir: URL {
        let base: URL
        if AppGroup.available { base = AppGroup.container }
        else { base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
        let d = base.appendingPathComponent("geo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var ipFile: URL { dir.appendingPathComponent("geoip.dat") }
    static var siteFile: URL { dir.appendingPathComponent("geosite.dat") }

    static var available: Bool {
        FileManager.default.fileExists(atPath: ipFile.path) && FileManager.default.fileExists(atPath: siteFile.path)
    }

    static func age(_ url: URL) -> TimeInterval? {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(d)
    }

    static func sizeMB(_ url: URL) -> Double {
        let n = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
        return n / 1_048_576
    }

    // MARK: загрузка

    static func download(ip: String, site: String) async throws {
        try await fetch(ip, to: ipFile)
        try await fetch(site, to: siteFile)
    }

    private static func fetch(_ urlString: String, to dest: URL) async throws {
        guard let url = URL(string: urlString) else { throw GeoError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GeoError.http(http.statusCode) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 10_000 else { throw GeoError.tooSmall }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    // MARK: чтение категорий

    // geoip:<code> -> список CIDR
    static func cidrs(code: String, limit: Int) -> [String]? {
        guard limit > 0 else { return [] }
        guard let data = try? Data(contentsOf: ipFile, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [String]? in
            let top = PBReader(buf)
            guard let range = findEntry(top, code: code) else { return nil }
            var out: [String] = []
            var e = top.sub(range)
            while let f = e.next() {
                guard case .bytes(2, let cr) = f else { continue }
                var c = top.sub(cr)
                var ipRange = 0..<0
                var prefix = 0
                while let g = c.next() {
                    switch g {
                    case .bytes(1, let r): ipRange = r
                    case .varint(2, let v): prefix = Int(v)
                    default: break
                    }
                }
                if let s = formatCIDR(buf, ipRange, prefix) {
                    out.append(s)
                    if out.count >= limit { break }
                }
            }
            return out
        }
    }

    // geosite:<code>[@attr] -> список правил Xray (domain:/full:/keyword:/regexp:)
    static func domains(code: String, limit: Int) -> [String]? {
        guard limit > 0 else { return [] }
        var name = code
        var wantAttr: String?
        if let at = code.firstIndex(of: "@") {
            name = String(code[..<at])
            wantAttr = String(code[code.index(after: at)...]).lowercased()
        }
        guard let data = try? Data(contentsOf: siteFile, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [String]? in
            let top = PBReader(buf)
            guard let range = findEntry(top, code: name) else { return nil }
            var out: [String] = []
            var e = top.sub(range)
            while let f = e.next() {
                guard case .bytes(2, let dr) = f else { continue }
                var d = top.sub(dr)
                var type = 0
                var value = ""
                var attrs: [String] = []
                while let g = d.next() {
                    switch g {
                    case .varint(1, let v): type = Int(v)
                    case .bytes(2, let r): value = top.string(r)
                    case .bytes(3, let r):
                        var a = top.sub(r)
                        while let h = a.next() {
                            if case .bytes(1, let kr) = h { attrs.append(top.string(kr).lowercased()); break }
                        }
                    default: break
                    }
                }
                if let w = wantAttr, !attrs.contains(w) { continue }
                guard !value.isEmpty else { continue }
                switch type {
                case 1: out.append("regexp:" + value)
                case 2: out.append("domain:" + value)
                case 3: out.append("full:" + value)
                default: out.append("keyword:" + value)
                }
                if out.count >= limit { break }
            }
            return out
        }
    }

    // MARK: helpers

    // Запись верхнего уровня (поле 1) с country_code == code; country_code — первое поле записи
    private static func findEntry(_ top: PBReader, code: String) -> Range<Int>? {
        var r = top
        let want = code.uppercased()
        while let f = r.next() {
            guard case .bytes(1, let range) = f else { continue }
            var e = r.sub(range)
            while let g = e.next() {
                if case .bytes(1, let cr) = g {
                    if r.string(cr).uppercased() == want { return range }
                    break
                }
            }
        }
        return nil
    }

    private static func formatCIDR(_ buf: UnsafeRawBufferPointer, _ range: Range<Int>, _ prefix: Int) -> String? {
        let b = Array(buf[range])
        if b.count == 4 { return "\(b[0]).\(b[1]).\(b[2]).\(b[3])/\(prefix)" }
        if b.count == 16 {
            var parts: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                parts.append(String(format: "%x", (Int(b[i]) << 8) | Int(b[i + 1])))
            }
            return parts.joined(separator: ":") + "/\(prefix)"
        }
        return nil
    }
}

// Минимальный читатель protobuf (varint и length-delimited поля)
private struct PBReader {
    enum Field {
        case varint(Int, UInt64)
        case bytes(Int, Range<Int>)
        case other
    }

    let p: UnsafeRawBufferPointer
    var pos: Int
    let end: Int

    init(_ p: UnsafeRawBufferPointer, pos: Int = 0, end: Int? = nil) {
        self.p = p
        self.pos = pos
        self.end = end ?? p.count
    }

    mutating func varint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < end, shift < 64 {
            let b = p[pos]
            pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func next() -> Field? {
        guard pos < end, let key = varint() else { return nil }
        let num = Int(key >> 3)
        switch key & 7 {
        case 0:
            guard let v = varint() else { return nil }
            return .varint(num, v)
        case 2:
            guard let len = varint() else { return nil }
            let l = Int(len)
            guard l >= 0, pos + l <= end else { return nil }
            let r = pos..<(pos + l)
            pos += l
            return .bytes(num, r)
        case 1:
            pos += 8
            return .other
        case 5:
            pos += 4
            return .other
        default:
            return nil
        }
    }

    func string(_ r: Range<Int>) -> String {
        String(decoding: UnsafeRawBufferPointer(rebasing: p[r]), as: UTF8.self)
    }

    func sub(_ r: Range<Int>) -> PBReader {
        PBReader(p, pos: r.lowerBound, end: r.upperBound)
    }
}
