import Foundation

/// Link-tail rules, `spec/link-rules.json` (format 1). Algorithm: `spec/link-rules.md`.
public struct LinkRules: Decodable, Sendable {
    public enum TailClass: String, Decodable, Sendable { case needed, tracks, givesAway = "gives_away" }
    public enum Mode: String, Decodable, Sendable { case allow, deny }
    public enum Confidence: String, Decodable, Sendable { case high, medium, low }

    public struct Param: Decodable, Sendable {
        public let name: String?
        public let prefix: String?
        public let values: [String]?
        public let `class`: TailClass
        public let confidence: Confidence
        public let note: String?
    }

    public struct Domain: Decodable, Sendable {
        public let id: String
        public let hosts: [String]
        public let mode: Mode
        public let unknownClass: TailClass?
        public let params: [Param]

        enum CodingKeys: String, CodingKey { case id, hosts, mode, unknownClass = "unknown_class", params }
    }

    public struct ShortLink: Decodable, Sendable {
        public let host: String
        public let pathPrefix: String?

        enum CodingKeys: String, CodingKey { case host, pathPrefix = "path_prefix" }
    }

    public struct SharingApp: Decodable, Sendable {
        public let id: String
        public let kind: String?
        public let mac: [String]
        public let win: [String]
    }

    public struct Global: Decodable, Sendable { public let params: [Param] }

    public let format: Int
    public let version: Int
    public let updated: String
    public let sharingApps: [SharingApp]
    public let shortLinks: [ShortLink]
    public let global: Global
    public let domains: [Domain]

    enum CodingKeys: String, CodingKey {
        case format, version, updated, global, domains
        case sharingApps = "sharing_apps", shortLinks = "short_links"
    }

    public enum LoadError: Error, CustomStringConvertible {
        case invalid([String])
        public var description: String {
            switch self { case .invalid(let p): return "invalid rules: " + p.joined(separator: "; ") }
        }
    }

    /// Decodes and validates. A file that fails either is rejected whole: the caller keeps the rules it had.
    public static func load(_ data: Data) throws -> LinkRules {
        let rules = try JSONDecoder().decode(LinkRules.self, from: data)
        let problems = rules.problems()
        if !problems.isEmpty { throw LoadError.invalid(problems) }
        return rules
    }

    /// Same checks as `validate` in `spec/tools/check-link-rules.py`.
    public func problems() -> [String] {
        var out: [String] = []
        if format != 1 { out.append("format must be 1") }
        if version < 1 { out.append("version must be an integer >= 1") }
        if updated.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil {
            out.append("updated must be YYYY-MM-DD")
        }
        func check(_ owner: String, _ params: [Param]) {
            for p in params {
                if (p.name == nil) == (p.prefix == nil) { out.append("\(owner): exactly one of name/prefix") }
                if let v = p.values, v.isEmpty { out.append("\(owner): values must be a non-empty list") }
            }
        }
        check("global", global.params)
        if global.params.contains(where: { $0.class == .needed }) { out.append("global: needed makes no sense") }
        var seen: [String: String] = [:]
        for d in domains {
            if d.mode == .allow, d.unknownClass == nil || d.unknownClass == .needed {
                out.append("\(d.id): allow needs unknown_class tracks|gives_away")
            }
            check(d.id, d.params)
            for h in d.hosts {
                if h != h.lowercased() || seen[h] != nil { out.append("host \(h): not lowercase or repeated") }
                seen[h] = d.id
            }
        }
        for s in shortLinks where s.host != s.host.lowercased() || (s.pathPrefix.map { !$0.hasPrefix("/") } ?? false) {
            out.append("short_links: \(s.host)")
        }
        for a in sharingApps where a.id.isEmpty || (a.mac.isEmpty && a.win.isEmpty) {
            out.append("sharing_apps: \(a.id)")
        }
        return out
    }
}

extension LinkRules.Param {
    /// Key of the rule for coverage checks, identical to `entry_key` in the reference.
    func key(_ owner: String) -> String {
        var k = "\(owner):" + (name ?? (prefix ?? "") + "*")
        if let values { k += "=" + values.joined(separator: ",") }
        return k
    }

    func matches(name n: String, value: String) -> Bool {
        if let name, !LinkCleaner.same(name.lowercased(), n) { return false }
        if let prefix, !LinkCleaner.hasPrefix(n, prefix.lowercased()) { return false }
        if let values { return values.contains { LinkCleaner.same($0, value) } }
        return true
    }
}

extension LinkRules {
    /// Every rule key a corpus must trigger at least once.
    public var allRuleKeys: Set<String> {
        var keys = Set(global.params.map { $0.key("global") })
        for d in domains {
            keys.formUnion(d.params.map { $0.key(d.id) })
            if d.mode == .allow { keys.insert("\(d.id):*") }
        }
        return keys
    }
}
