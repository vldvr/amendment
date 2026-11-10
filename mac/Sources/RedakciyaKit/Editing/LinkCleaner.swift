import Foundation

/// Result of cleaning one clipboard string.
public struct CleanedLink: Equatable, Sendable {
    public enum Kind: String, Sendable { case givesAway = "gives_away", tracks, none }
    /// What the user sees: a card, a silent counter bump, or nothing.
    public enum Show: String, Sendable { case card, silent, none }

    public let output: String
    public let kind: Kind
    /// Decoded, lowercased names of removed parameters, in input order (query first, then fragment).
    public let removed: [String]
    /// `id` of the matched domain rule, for wording ("instagram", "youtube"…); nil for global rules only.
    public var domain: String? = nil

    public var show: Show {
        switch kind { case .givesAway: return .card; case .tracks: return .silent; case .none: return .none }
    }
}

/// Algorithm of `spec/link-rules.md`, step for step with `spec/tools/check-link-rules.py`.
/// Works on Unicode scalars, as Python works on code points: a combining mark after `?` must not hide it.
public struct LinkCleaner: Sendable {
    public let rules: LinkRules

    public init(rules: LinkRules) { self.rules = rules }

    public func clean(_ url: String) -> CleanedLink {
        var fired = Set<String>()
        return clean(url, fired: &fired)
    }

    /// `fired` collects the keys of rules that matched, for the corpus coverage check.
    public func clean(_ url: String, fired: inout Set<String>) -> CleanedLink {
        let same = CleanedLink(output: url, kind: .none, removed: [])
        guard let parts = Self.split(url) else { return same }
        let host = Self.host(of: parts.authority)
        if host.isEmpty { return same }

        for s in rules.shortLinks where Self.hostMatches(host, s.host) && Self.hasPrefix(parts.path, s.pathPrefix ?? "") {
            return same
        }

        var domain: LinkRules.Domain?
        var best = -1
        for d in rules.domains {
            for h in d.hosts where Self.hostMatches(host, h) && h.unicodeScalars.count > best {
                domain = d
                best = h.unicodeScalars.count
            }
        }

        var removed: [(String, LinkRules.TailClass)] = []
        var newQuery: String?
        if let q = parts.query, !q.isEmpty {
            newQuery = filter(q, domain: domain, inFragment: false, removed: &removed, fired: &fired)
        }

        var newFragment: String?
        if let frag = parts.fragment, !frag.isEmpty {
            let (head, sep, tail) = Self.partition(frag, ":~:")
            let segs = Self.splitScalars(head, "&").filter { !$0.isEmpty }
            if !segs.isEmpty, segs.allSatisfy({ $0.unicodeScalars.contains("=") }),
               !head.unicodeScalars.contains("/"), !head.unicodeScalars.contains("?"),
               let r = filter(head, domain: domain, inFragment: true, removed: &removed, fired: &fired) {
                newFragment = r + sep + tail
            }
        }

        if removed.isEmpty { return same }
        var out = parts.scheme + parts.authority + parts.path
        if let q = newQuery ?? parts.query, !q.isEmpty { out += "?" + q }
        if let f = newFragment ?? parts.fragment, !f.isEmpty {
            out += "#" + f
        } else if parts.fragment == "", newFragment == nil {
            out += "#"
        }
        let kind: CleanedLink.Kind = removed.contains { $0.1 == .givesAway } ? .givesAway : .tracks
        return CleanedLink(output: out, kind: kind, removed: removed.map(\.0), domain: domain?.id)
    }

    // MARK: - parameters

    private func classify(_ name: String, _ value: String, _ domain: LinkRules.Domain?, inFragment: Bool,
                          fired: inout Set<String>) -> LinkRules.TailClass? {
        if let domain, let p = domain.params.first(where: { $0.matches(name: name, value: value) }) {
            fired.insert(p.key(domain.id))
            return p.class
        }
        if let p = rules.global.params.first(where: { $0.matches(name: name, value: value) }) {
            fired.insert(p.key("global"))
            return p.class
        }
        if let domain, domain.mode == .allow, !inFragment {
            fired.insert("\(domain.id):*")
            return domain.unknownClass
        }
        return nil
    }

    /// The rebuilt text, or nil when nothing was removed. Kept segments stay byte for byte.
    private func filter(_ text: String, domain: LinkRules.Domain?, inFragment: Bool,
                        removed: inout [(String, LinkRules.TailClass)], fired: inout Set<String>) -> String? {
        var kept: [String] = []
        var dropped = false
        for seg in Self.splitScalars(text, "&") where !seg.isEmpty {
            let (rawName, _, rawValue) = Self.partition(seg, "=")
            let name = Self.percentDecode(rawName).lowercased()
            let cls = classify(name, Self.percentDecode(rawValue), domain, inFragment: inFragment, fired: &fired)
            if cls == .tracks || cls == .givesAway {
                dropped = true
                removed.append((name, cls!))
            } else {
                kept.append(seg)
            }
        }
        return dropped ? kept.joined(separator: "&") : nil
    }

    // MARK: - parsing

    struct Parts { let scheme, authority, path: String; let query, fragment: String? }

    /// nil if the string is not a single http(s) URL.
    static func split(_ url: String) -> Parts? {
        if url.unicodeScalars.contains(where: isSpace) { return nil }
        let lower = url.unicodeScalars.prefix(8).map { Character($0).lowercased() }.joined()
        let schemeLength: Int
        if lower.hasPrefix("https://") { schemeLength = 8 } else if lower.hasPrefix("http://") { schemeLength = 7 } else { return nil }
        let scalars = url.unicodeScalars
        let schemeEnd = scalars.index(scalars.startIndex, offsetBy: schemeLength)
        let scheme = String(scalars[..<schemeEnd])
        var rest = String(scalars[schemeEnd...])
        var fragment: String?
        var query: String?
        if rest.unicodeScalars.contains("#") {
            let (a, _, b) = partition(rest, "#")
            rest = a
            fragment = b
        }
        if rest.unicodeScalars.contains("?") {
            let (a, _, b) = partition(rest, "?")
            rest = a
            query = b
        }
        let (authority, slash, tail) = partition(rest, "/")
        return Parts(scheme: scheme, authority: authority, path: slash + tail, query: query, fragment: fragment)
    }

    static func host(of authority: String) -> String {
        var h = authority
        if let at = h.unicodeScalars.lastIndex(of: "@") {
            h = String(h.unicodeScalars[h.unicodeScalars.index(after: at)...])
        }
        if !h.unicodeScalars.starts(with: "[".unicodeScalars) { h = partition(h, ":").0 }
        h = h.lowercased()
        while h.unicodeScalars.last == "." { h = String(h.unicodeScalars.dropLast()) }
        return h
    }

    static func hostMatches(_ host: String, _ ruleHost: String) -> Bool {
        same(host, ruleHost) || hasSuffix(host, "." + ruleHost)
    }

    /// String comparison by code points, as in Python. Swift's `==` uses canonical equivalence.
    static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }
    static func hasPrefix(_ s: String, _ p: String) -> Bool { s.unicodeScalars.starts(with: p.unicodeScalars) }
    static func hasSuffix(_ s: String, _ p: String) -> Bool {
        s.unicodeScalars.reversed().starts(with: p.unicodeScalars.reversed())
    }

    /// Python's `str.isspace`: Unicode whitespace plus the separators U+001C–U+001F.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || (0x1C...0x1F).contains(s.value)
    }

    /// `str.partition` on scalars: (before, separator or "", after).
    static func partition(_ s: String, _ sep: String) -> (String, String, String) {
        let hay = Array(s.unicodeScalars), needle = Array(sep.unicodeScalars)
        guard !needle.isEmpty, hay.count >= needle.count else { return (s, "", "") }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<i + needle.count]) == needle {
            return (str(hay[..<i]), sep, str(hay[(i + needle.count)...]))
        }
        return (s, "", "")
    }

    /// `str.split(sep)` on scalars for a one-scalar separator.
    static func splitScalars(_ s: String, _ sep: Unicode.Scalar) -> [String] {
        s.unicodeScalars.split(separator: sep, omittingEmptySubsequences: false).map { String($0) }
    }

    private static func str<C: Collection>(_ c: C) -> String where C.Element == Unicode.Scalar {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: c)
        return String(v)
    }

    /// Python's `urllib.parse.unquote`: `%XX` inside ASCII runs become bytes, decoded as UTF-8 with U+FFFD
    /// for bad bytes; malformed `%` stays; `+` stays; non-ASCII characters pass through.
    static func percentDecode(_ s: String) -> String {
        guard s.unicodeScalars.contains("%") else { return s }
        var out = ""
        var run: [UInt8] = []
        func flush() {
            guard !run.isEmpty else { return }
            var bytes: [UInt8] = []
            var i = 0
            while i < run.count {
                if run[i] == 0x25, i + 2 < run.count, let hi = hex(run[i + 1]), let lo = hex(run[i + 2]) {
                    bytes.append(hi << 4 | lo)
                    i += 3
                } else {
                    bytes.append(run[i])
                    i += 1
                }
            }
            out += String(decoding: bytes, as: UTF8.self)
            run.removeAll()
        }
        for scalar in s.unicodeScalars {
            if scalar.isASCII {
                run.append(UInt8(scalar.value))
            } else {
                flush()
                out.unicodeScalars.append(scalar)
            }
        }
        flush()
        return out
    }

    private static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x37
        case 0x61...0x66: return b - 0x57
        default: return nil
        }
    }
}
