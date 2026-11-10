import AppKit
import CryptoKit
import Foundation

/// 12 Russian words = 128 random bits + 4 bits of SHA-256 checksum, 11 bits per word (as BIP-39).
/// The recovery X25519 key is HKDF-SHA256(entropy, salt "redakciya/recovery/v1", info "age-x25519").
/// Words are only an encoding of the entropy, so a fast KDF is enough.
enum Recovery {
    /// spec/recovery-words-ru.txt, built in by scripts/sync-spec.sh.
    static let list: [String] = (try? parseWords(BundledRecoveryWords.text)) ?? []

    static func parseWords(_ text: String) throws -> [String] {
        let words = text
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard words.count == 2048 else { throw AgeError.malformed("word list has \(words.count) words, need 2048") }
        return words
    }

    static func newEntropy() -> Data {
        var e = Data(count: 16)
        _ = e.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return e
    }

    /// The 12 word numbers (0-2047): independent of the word list, so they go into test vectors.
    static func indices(for entropy: Data) -> [Int] {
        let checksum = Data(SHA256.hash(data: entropy))[0] >> 4
        var bits: [Bool] = []
        for byte in entropy { for i in (0..<8).reversed() { bits.append((byte >> UInt8(i)) & 1 == 1) } }
        for i in (0..<4).reversed() { bits.append((checksum >> UInt8(i)) & 1 == 1) }
        return (0..<12).map { w in (0..<11).reduce(0) { $0 << 1 | (bits[w * 11 + $1] ? 1 : 0) } }
    }

    static func words(for entropy: Data, list: [String]) -> [String] {
        let checksum = Data(SHA256.hash(data: entropy))[0] >> 4
        var bits: [Bool] = []
        for byte in entropy { for i in (0..<8).reversed() { bits.append((byte >> UInt8(i)) & 1 == 1) } }
        for i in (0..<4).reversed() { bits.append((checksum >> UInt8(i)) & 1 == 1) }
        return (0..<12).map { w in
            let idx = (0..<11).reduce(0) { $0 << 1 | (bits[w * 11 + $1] ? 1 : 0) }
            return list[idx]
        }
    }

    /// Accepts any case, ё for е, and the first four letters of each word.
    static func entropy(from words: [String], list: [String]) throws -> Data {
        guard words.count == 12 else { throw AgeError.malformed("need 12 words, got \(words.count)") }
        var bits: [Bool] = []
        for w in words {
            let n = normalize(w)
            let matches = list.indices.filter { list[$0] == n || (n.count >= 4 && list[$0].hasPrefix(n)) }
            guard matches.count == 1 else { throw AgeError.malformed("unknown word «\(w)»") }
            for i in (0..<11).reversed() { bits.append((matches[0] >> i) & 1 == 1) }
        }
        var entropy = Data()
        for b in 0..<16 { entropy.append((0..<8).reduce(UInt8(0)) { $0 << 1 | (bits[b * 8 + $1] ? 1 : 0) }) }
        let checksum = (0..<4).reduce(UInt8(0)) { $0 << 1 | (bits[128 + $1] ? 1 : 0) }
        guard checksum == Data(SHA256.hash(data: entropy))[0] >> 4 else {
            throw AgeError.malformed("checksum mismatch: a word is wrong or out of order")
        }
        return entropy
    }

    static func normalize(_ w: String) -> String {
        w.lowercased().replacingOccurrences(of: "ё", with: "е").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func identity(from entropy: Data) -> X25519Identity {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: entropy),
                                         salt: Data("redakciya/recovery/v1".utf8),
                                         info: Data("age-x25519".utf8), outputByteCount: 32)
        let raw = key.withUnsafeBytes { Data($0) }
        return X25519Identity(privateKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw))
    }
}

/// The built-in word list as text, for the `bundled` check.
public enum RecoveryWordsCopy {
    public static var text: String { BundledRecoveryWords.text }
}
