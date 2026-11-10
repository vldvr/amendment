import Foundation

/// A value for a placeholder: a number picks word forms and number words, text goes in as is.
public enum GazetteValue: Sendable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case n(Int)
    case s(String)

    public init(integerLiteral value: Int) { self = .n(value) }
    public init(stringLiteral value: String) { self = .s(value) }

    var text: String {
        switch self { case .n(let n): return String(n); case .s(let s): return s }
    }

    var number: Int {
        switch self { case .n(let n): return n; case .s(let s): return Int(s) ?? 0 }
    }
}

/// Templates of the morning issue (spec/gazette.md, «Шаблоны»), step for step with spec/tools/check-gazette.py.
public struct GazetteTemplates: Sendable {
    public enum Problem: Error, CustomStringConvertible {
        case badLine(String)
        case missing(String)
        public var description: String {
            switch self { case .badLine(let l): return "bad template line: \(l)"; case .missing(let k): return "no template \(k)" }
        }
    }

    public private(set) var texts: [String: String] = [:]
    public var platform: String

    public init(_ text: String, platform: String = "mac") throws {
        self.platform = platform
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.allSatisfy(\.isWhitespace) || line.hasPrefix("#") { continue }
            guard let r = line.range(of: " = "), texts[String(line[..<r.lowerBound])] == nil else {
                throw Problem.badLine(String(line))
            }
            texts[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
        }
    }

    public static let bundled = try! GazetteTemplates(BundledGazetteTemplates.text)
    public static var bundledText: String { BundledGazetteTemplates.text }

    /// The text of a key; the platform's own variant wins.
    public func raw(_ key: String) -> String {
        texts["\(key).\(platform)"] ?? texts[key] ?? "{\(key)}"
    }

    public func has(_ key: String) -> Bool { texts["\(key).\(platform)"] != nil || texts[key] != nil }

    public func list(_ key: String) -> [String] { raw(key).components(separatedBy: "|") }

    public func callAsFunction(_ key: String, _ values: [String: GazetteValue] = [:]) -> String {
        render(raw(key), values)
    }

    private static let placeholder = try! NSRegularExpression(
        pattern: #"\{([a-z_]+)(?:~([mfn]))?(\^)?(?:\|([^{}|]*)\|([^{}|]*)\|([^{}|]*))?\}"#)

    /// One pass: substituted values are not scanned again.
    public func render(_ text: String, _ values: [String: GazetteValue]) -> String {
        let ns = text as NSString
        var out = "", at = 0
        for m in Self.placeholder.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = m.range.location + m.range.length
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let value = values[group(1)!] else {
                out += ns.substring(with: m.range)
                continue
            }
            var piece: String
            if let one = group(4), let few = group(5), let many = group(6) {
                piece = [one, few, many][Self.plural(value.number)]
            } else if let gender = group(2) {
                let words = list("number." + gender), n = value.number
                piece = (1...words.count).contains(n) ? words[n - 1] : String(n)
            } else {
                piece = value.text
            }
            if group(3) != nil { piece = piece.prefix(1).uppercased() + piece.dropFirst() }
            out += piece
        }
        return out + ns.substring(from: at)
    }

    /// Russian word form by number: 0 for 1, 21, 101; 1 for 2–4, 22–24; 2 for the rest.
    public static func plural(_ n: Int) -> Int {
        let n = abs(n)
        if n % 10 == 1 && n % 100 != 11 { return 0 }
        if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return 1 }
        return 2
    }
}
