import CryptoKit
import Foundation

// age v1 (https://age-encryption.org/v1), just enough for the archive: header with stanzas,
// header MAC, STREAM payload. Written from the spec, checked against the reference CLI.

enum AgeError: Error, CustomStringConvertible {
    case malformed(String)
    case noIdentityMatched
    case badMAC
    case badPayload(String)

    var description: String {
        switch self {
        case .malformed(let s): return "malformed age file: \(s)"
        case .noIdentityMatched: return "no identity matched any recipient"
        case .badMAC: return "header MAC mismatch"
        case .badPayload(let s): return "payload: \(s)"
        }
    }
}

/// Standard base64 alphabet without padding, as age uses it.
enum RawBase64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        guard !s.contains("=") else { return nil }
        let padded = s + String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
}

struct Stanza {
    var type: String
    var args: [String]
    var body: Data

    var encoded: String {
        var out = "-> " + ([type] + args).joined(separator: " ") + "\n"
        let b64 = RawBase64.encode(body)
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[i..<j] + "\n"
            i = j
        }
        // The last body line must be shorter than 64 columns, so a full last line gets an empty one.
        if b64.count % 64 == 0 { out += "\n" }
        return out
    }
}

/// Wraps the 16-byte file key for one recipient.
protocol AgeRecipient {
    func wrap(fileKey: Data) throws -> Stanza
}

/// Tries to unwrap the file key from the stanzas it understands; nil if none is for it.
protocol AgeIdentity {
    func unwrap(stanzas: [Stanza]) throws -> Data?
}

enum Age {
    static let intro = "age-encryption.org/v1\n"
    static let chunkSize = 64 * 1024

    static func hkdf(_ ikm: Data, salt: Data, info: String, count: Int = 32) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                               info: Data(info.utf8), outputByteCount: count)
    }

    /// ChaCha20-Poly1305 with an all-zero nonce, used to wrap file keys.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard sealed.count >= 16 else { throw AgeError.malformed("short sealed box") }
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)),
                                           ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try ChaChaPoly.open(box, using: key)
    }

    // MARK: Encrypt

    static func encrypt(_ plaintext: Data, to recipients: [AgeRecipient]) throws -> Data {
        var fileKey = Data(count: 16)
        _ = fileKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }

        var header = intro
        for r in recipients { header += try r.wrap(fileKey: fileKey).encoded }
        header += "---"
        let macKey = hkdf(fileKey, salt: Data(), info: "header")
        let mac = Data(HMAC<SHA256>.authenticationCode(for: Data(header.utf8), using: macKey))
        header += " " + RawBase64.encode(mac) + "\n"

        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let payloadKey = hkdf(fileKey, salt: nonce, info: "payload")

        var out = Data(header.utf8) + nonce
        var counter: UInt64 = 0
        var offset = 0
        repeat {
            let end = min(offset + chunkSize, plaintext.count)
            let last = end == plaintext.count
            let chunk = plaintext[offset..<end]
            let box = try ChaChaPoly.seal(chunk, using: payloadKey, nonce: streamNonce(counter, last: last))
            out += box.ciphertext + box.tag
            counter += 1
            offset = end
        } while offset < plaintext.count
        return out
    }

    /// 11-byte big-endian counter and a final-chunk flag.
    static func streamNonce(_ counter: UInt64, last: Bool) throws -> ChaChaPoly.Nonce {
        var n = Data(count: 12)
        for i in 0..<8 { n[10 - i] = UInt8((counter >> (8 * UInt64(i))) & 0xff) }
        n[11] = last ? 1 : 0
        return try ChaChaPoly.Nonce(data: n)
    }

    // MARK: Decrypt

    struct Header {
        var stanzas: [Stanza]
        var macInput: Data
        var mac: Data
        var payloadOffset: Int
    }

    static func parseHeader(_ file: Data) throws -> Header {
        var lines: [(String, Int)] = []   // line text and the offset just past its newline
        var start = 0
        var stanzas: [Stanza] = []
        func nextLine() throws -> String {
            guard let nl = file[start...].firstIndex(of: 0x0A) else { throw AgeError.malformed("unterminated header") }
            guard let s = String(data: file[start..<nl], encoding: .utf8) else { throw AgeError.malformed("non-UTF-8 header") }
            start = nl + 1
            lines.append((s, start))
            return s
        }
        guard try nextLine() + "\n" == intro else { throw AgeError.malformed("bad intro line") }
        var line = try nextLine()
        while line.hasPrefix("-> ") {
            let parts = line.dropFirst(3).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let type = parts.first, !type.isEmpty else { throw AgeError.malformed("empty stanza type") }
            var b64 = ""
            while true {
                let bodyLine = try nextLine()
                guard bodyLine.count <= 64 else { throw AgeError.malformed("body line too long") }
                b64 += bodyLine
                if bodyLine.count < 64 { break }
            }
            guard let body = RawBase64.decode(b64) else { throw AgeError.malformed("bad stanza body") }
            stanzas.append(Stanza(type: type, args: Array(parts.dropFirst()), body: body))
            line = try nextLine()
        }
        guard line.hasPrefix("--- "), let mac = RawBase64.decode(String(line.dropFirst(4))), mac.count == 32 else {
            throw AgeError.malformed("bad MAC line")
        }
        // The MAC covers everything up to and including "---".
        let macLineStart = lines[lines.count - 2].1
        let macInput = file[0..<(macLineStart + 3)]
        return Header(stanzas: stanzas, macInput: Data(macInput), mac: mac, payloadOffset: start)
    }

    static func decrypt(_ file: Data, with identities: [AgeIdentity]) throws -> Data {
        let header = try parseHeader(file)
        var fileKey: Data?
        for id in identities {
            if let k = try id.unwrap(stanzas: header.stanzas) { fileKey = k; break }
        }
        guard let fileKey else { throw AgeError.noIdentityMatched }
        let macKey = hkdf(fileKey, salt: Data(), info: "header")
        guard HMAC<SHA256>.isValidAuthenticationCode(header.mac, authenticating: header.macInput, using: macKey) else {
            throw AgeError.badMAC
        }

        var p = header.payloadOffset
        guard file.count >= p + 16 else { throw AgeError.badPayload("missing nonce") }
        let nonce = file[p..<(p + 16)]
        p += 16
        let payloadKey = hkdf(fileKey, salt: Data(nonce), info: "payload")
        var out = Data()
        var counter: UInt64 = 0
        let sealedChunk = chunkSize + 16
        while true {
            let remaining = file.count - p
            guard remaining >= 16 else { throw AgeError.badPayload("truncated") }
            let last = remaining <= sealedChunk
            let end = p + min(remaining, sealedChunk)
            let box = try ChaChaPoly.SealedBox(nonce: streamNonce(counter, last: last),
                                               ciphertext: file[p..<(end - 16)], tag: file[(end - 16)..<end])
            let plain = try ChaChaPoly.open(box, using: payloadKey)
            if last && plain.isEmpty && counter > 0 { throw AgeError.badPayload("empty last chunk") }
            out += plain
            p = end
            counter += 1
            if last { break }
        }
        return out
    }
}
