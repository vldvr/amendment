import Foundation

/// Pure rules of spec/reprint.md and the code reader of spec/issue-code.md.
public enum ReprintRules {
    public static let alphabet: Set<Character> = Set("2345679ABCEHJKMPRSTUVWXY")
    static let alphabetList = Array("2345679ABCEHJKMPRSTUVWXY")
    static let lookalikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P",
        "С": "C", "Т": "T", "У": "Y", "Х": "X", "З": "3", "Б": "6",
    ]
    static let twins: [Character: Character] = ["8": "B", "N": "M", "Z": "7", "F": "E", "G": "6"]
    static let unreadSet: Set<Character> = ["O", "0", "Q", "D"]
    public static let maxPurpose = 60
    public static let life: TimeInterval = 86400

    // MARK: Purpose

    public enum PurposeError: Error, LocalizedError, Equatable {
        case empty, tooLong
        public var errorDescription: String? {
            self == .empty ? "Напишите, для кого копия." : "Не длиннее \(maxPurpose) знаков."
        }
    }

    public static func purpose(_ raw: String) -> Result<String, PurposeError> {
        var s = ""
        for ch in raw where ch != "№" {
            if ch.isWhitespace { s.append(" "); continue }
            if ch.unicodeScalars.allSatisfy({ $0.value < 32 || $0.value == 127 }) { continue }
            s.append(ch)
        }
        s = s.replacingOccurrences(of: " +", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^(?i)для(?![\p{L}\p{N}])\s*:?\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[,.;: ]+$", with: "", options: .regularExpression)
        if s.isEmpty { return .failure(.empty) }
        if s.count > maxPurpose { return .failure(.tooLong) }
        return .success(s)
    }

    // MARK: Codes

    static func distance(_ a: String, _ b: String) -> Int { zip(a, b).filter { $0 != $1 }.count }

    public static func codeOK(_ code: String, journal: [String]) -> Bool {
        code.count == 4 && code.allSatisfy(alphabet.contains) && journal.allSatisfy { distance(code, $0) >= 2 }
    }

    public struct JournalFull: Error, LocalizedError { public var errorDescription: String? { "Журнал выдач заполнен." } }

    public static func newCode(journal: [String]) throws -> String {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<10_000 {
            let c = String((0..<4).map { _ in alphabetList.randomElement(using: &rng)! })
            if codeOK(c, journal: journal) { return c }
        }
        throw JournalFull()
    }

    public static func fileName(code: String, ext: String, taken: (String) -> Bool) -> String {
        var name = "Копия \(code).\(ext)", n = 2
        while taken(name) { name = "Копия \(code) \(n).\(ext)"; n += 1 }
        return name
    }

    public static func spoiled(issued: Date, now: Date) -> Bool { now.timeIntervalSince(issued) >= life }

    // MARK: Reader (issue-code.md, «Чтение кода»)

    public enum Found: Equatable { case code(String, fuzzy: Bool), ambiguous([String]), none }

    static let signed = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:№\s*|N[º°O0Q2!':]\.?\s*|N\.?\s+|H[:']\s*)([0-9A-Z]{4}|[0-9A-Z]{2} [0-9A-Z]{2})(?![\p{L}\p{N}])"#)
    static let bare = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])[0-9A-Z]{4}(?![\p{L}\p{N}])"#)

    static func normalize(_ s: String) -> String { String(s.uppercased().map { lookalikes[$0] ?? $0 }) }
    static func twin(_ s: String) -> String { String(s.map { twins[$0] ?? $0 }) }
    static func unread(_ w: String) -> Int { w.filter(unreadSet.contains).count }

    struct Word: Hashable { let text: String; let signed: Bool }

    static func words(_ line: String) -> [Word] {
        let s = normalize(line)
        let ns = s as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out = signed.matches(in: s, range: all).map {
            Word(text: twin(ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: " ", with: "")), signed: true)
        }
        out += bare.matches(in: s, range: all).map { Word(text: twin(ns.substring(with: $0.range)), signed: false) }
        return out
    }

    static func matches(_ w: String, _ c: String) -> Bool {
        unread(w) <= 1 && zip(w, c).allSatisfy { $0 == $1 || unreadSet.contains($0) }
    }

    public static func find(lines: [String], journal: Set<String>) -> Found {
        let ws = Set(lines.flatMap(words))
        let signedWords = ws.filter(\.signed).map(\.text)
        var exact = Set<String>()
        for w in ws {
            if unread(w.text) > 0 && !w.signed { continue }
            exact.formUnion(journal.filter { matches(w.text, $0) })
        }
        if exact.count == 1 { return .code(exact.first!, fuzzy: false) }
        if exact.count > 1 {
            let pick = exact.filter { c in signedWords.contains { matches($0, c) } }
            return pick.count == 1 ? .code(pick.first!, fuzzy: false) : .ambiguous(exact.sorted())
        }
        let near = Set(journal.filter { c in signedWords.contains { unread($0) == 0 && distance($0, c) == 1 && $0.count == c.count } })
        if near.count == 1 { return .code(near.first!, fuzzy: true) }
        if near.count > 1 { return .ambiguous(near.sorted()) }
        return .none
    }

    // MARK: Search

    static func fold(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ё", with: "е") }

    static func codeLike(_ q: String) -> Bool {
        let w = twin(normalize(q.trimmingCharacters(in: .whitespaces)))
        return w.count == 4 && w.allSatisfy { alphabet.contains($0) || unreadSet.contains($0) }
    }

    /// Indices of matching issues, journal order.
    public static func search(_ query: String, in issues: [Issue]) -> [Int] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        if codeLike(q) {
            let hits: Set<String>
            switch find(lines: ["№ " + q], journal: Set(issues.map(\.code))) {
            case .code(let c, _): hits = [c]
            case .ambiguous(let cs): hits = Set(cs)
            case .none: hits = []
            }
            if !hits.isEmpty { return issues.indices.filter { hits.contains(issues[$0].code) } }
        }
        let f = fold(q)
        return issues.indices.filter { fold(issues[$0].purpose).contains(f) || fold(issues[$0].title).contains(f) }
    }
}
