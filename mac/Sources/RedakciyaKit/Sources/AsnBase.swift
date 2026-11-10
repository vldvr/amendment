import Foundation

/// A remote address as the kernel reports it.
public enum RemoteAddress: Equatable, Sendable {
    case v4(UInt32)
    case v6([UInt8])

    /// Where an address leads, by spec/sources.md: not counted, behind a VPN, or out in the world.
    public enum Reach: Equatable, Sendable { case local, vpn, world }

    public var reach: Reach {
        switch self {
        case .v4(let x):
            let a = x >> 24, b = (x >> 16) & 0xFF
            if a == 198 && (b == 18 || b == 19) { return .vpn }
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b)) { return .local }
            return .world
        case .v6(let b):
            guard b.count == 16 else { return .local }
            if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return .local }
            if b[0] == 0xFF || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] & 0xFE == 0xFC { return .local }
            return .world
        }
    }

    /// `a.b.c.d`, for checks.
    public init?(v4 text: String) {
        let p = text.split(separator: ".").compactMap { UInt8($0) }
        guard p.count == 4 else { return nil }
        self = .v4(p.reduce(0) { $0 << 8 | UInt32($1) })
    }
}

/// `asn.bin` (spec/sources.md, «База ASN»): IPv4 ranges with cleaned company names. Read in place, nothing is parsed up front.
public struct AsnBase: Sendable {
    public struct Company: Equatable, Sendable {
        public let name: String
        public let cloud: Bool
        public init(name: String, cloud: Bool) { self.name = name; self.cloud = cloud }
    }

    private let data: Data
    public let ranges: Int
    private let names: Int

    public init?(_ data: Data) {
        guard data.count >= 16, data.prefix(4) == Data("RASN".utf8) else { return nil }
        self.data = data
        guard Self.u32(data, 4) == 1 else { return nil }
        ranges = Int(Self.u32(data, 8))
        names = Int(Self.u32(data, 12))
        let tables = 16 + 12 * ranges + 4 * (names + 1)
        guard data.count >= tables, data.count == tables + Int(Self.u32(data, tables - 4)) else { return nil }
    }

    public init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(d)
    }

    /// The base next to the journal if there is one (it will come from the server), else the one shipped with the app.
    public static func installed() -> AsnBase? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Redakciya/asn.bin")
        return AsnBase(url: support) ?? Bundle.main.resourceURL.flatMap { AsnBase(url: $0.appendingPathComponent("asn.bin")) }
    }

    private static func u32(_ d: Data, _ offset: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    public func lookup(_ ip: UInt32) -> Company? {
        var lo = 0, hi = ranges - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if Self.u32(data, 16 + 4 * mid) <= ip { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, Self.u32(data, 16 + 4 * ranges + 4 * found) >= ip else { return nil }
        let name = Int(Self.u32(data, 16 + 8 * ranges + 4 * found))
        guard name < names else { return nil }
        let offsets = 16 + 12 * ranges, blob = offsets + 4 * (names + 1)
        let a = Int(Self.u32(data, offsets + 4 * name)), b = Int(Self.u32(data, offsets + 4 * name + 4))
        guard a < b, blob + b <= data.count else { return nil }
        let raw = data.subdata(in: (blob + a)..<(blob + b))
        return Company(name: String(decoding: raw.dropFirst(), as: UTF8.self), cloud: raw[raw.startIndex] & 1 == 1)
    }
}
