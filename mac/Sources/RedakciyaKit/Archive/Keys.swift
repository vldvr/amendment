import CryptoKit
import Foundation
import LocalAuthentication
import Security

// MARK: - Bech32 (BIP-173, without the 90-character limit, as age uses it)

enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 { chk ^= gen[i] }
        }
        return chk
    }

    private static func expand(_ hrp: String) -> [UInt8] {
        let b = Array(hrp.utf8)
        return b.map { $0 >> 5 } + [0] + b.map { $0 & 31 }
    }

    private static func convert(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0, bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        for v in data {
            acc = (acc << from) | Int(v)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    static func encode(hrp: String, data: Data) -> String {
        let values = convert(Array(data), from: 8, to: 5, pad: true)!
        let poly = polymod(expand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0..<6).map { UInt8((poly >> UInt32(5 * (5 - $0))) & 31) }
        return hrp + "1" + String((values + checksum).map { charset[Int($0)] })
    }

    static func decode(_ s: String) -> (hrp: String, data: Data)? {
        let lower = s.lowercased()
        guard lower == s || s.uppercased() == s, let sep = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[..<sep])
        var values: [UInt8] = []
        for c in lower[lower.index(after: sep)...] {
            guard let i = charset.firstIndex(of: c) else { return nil }
            values.append(UInt8(i))
        }
        guard values.count >= 6, polymod(expand(hrp) + values) == 1,
              let data = convert(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (hrp, Data(data))
    }
}

// MARK: - X25519 (the recovery key, readable by the stock age CLI)

struct X25519Recipient: AgeRecipient {
    let publicKey: Curve25519.KeyAgreement.PublicKey

    init(publicKey: Curve25519.KeyAgreement.PublicKey) { self.publicKey = publicKey }

    init?(_ s: String) {
        guard let (hrp, data) = Bech32.decode(s), hrp == "age", data.count == 32,
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) else { return nil }
        publicKey = key
    }

    var string: String { Bech32.encode(hrp: "age", data: publicKey.rawRepresentation) }

    func wrap(fileKey: Data) throws -> Stanza {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let share = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        guard shared != Data(count: 32) else { throw AgeError.malformed("all-zero shared secret") }
        let key = Age.hkdf(shared, salt: share + publicKey.rawRepresentation, info: "age-encryption.org/v1/X25519")
        return Stanza(type: "X25519", args: [RawBase64.encode(share)], body: try Age.seal(fileKey, key: key))
    }
}

struct X25519Identity: AgeIdentity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    init?(_ s: String) {
        guard let (hrp, data) = Bech32.decode(s), hrp == "age-secret-key-", data.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        privateKey = key
    }

    var string: String { Bech32.encode(hrp: "age-secret-key-", data: privateKey.rawRepresentation).uppercased() }
    var recipient: X25519Recipient { X25519Recipient(publicKey: privateKey.publicKey) }

    func unwrap(stanzas: [Stanza]) throws -> Data? {
        let mine = privateKey.publicKey.rawRepresentation
        for s in stanzas where s.type == "X25519" {
            guard s.args.count == 1, let share = RawBase64.decode(s.args[0]), share.count == 32,
                  s.body.count == 32,
                  let ephemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: share) else {
                throw AgeError.malformed("bad X25519 stanza")
            }
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral).withUnsafeBytes { Data($0) }
            let key = Age.hkdf(shared, salt: share + mine, info: "age-encryption.org/v1/X25519")
            if let fileKey = try? Age.open(s.body, key: key) { return fileKey }
        }
        return nil
    }
}

// MARK: - Secure Enclave P-256 (the device key, Touch ID or password on every use)

/// Stanza: `-> redakciya-p256 <tag> <ephemeral share>`, body = file key sealed with
/// HKDF-SHA256(ECDH(ephemeral, device), salt = share || device key, info = "redakciya/v1/p256").
/// Named by the algorithm, not the platform: a TPM key on Windows uses the same stanza.
/// tag = first 4 bytes of SHA-256 of the device public key, so other devices skip it without a prompt.
enum DeviceStanza {
    static let type = "redakciya-p256"
    static let info = "redakciya/v1/p256"

    static func tag(_ pub: P256.KeyAgreement.PublicKey) -> String {
        RawBase64.encode(Data(SHA256.hash(data: pub.compressedRepresentation)).prefix(4))
    }
}

struct DeviceRecipient: AgeRecipient {
    let publicKey: P256.KeyAgreement.PublicKey

    func wrap(fileKey: Data) throws -> Stanza {
        try wrap(fileKey: fileKey, ephemeral: P256.KeyAgreement.PrivateKey())
    }

    /// With a given ephemeral key, for test vectors only.
    func wrap(fileKey: Data, ephemeral: P256.KeyAgreement.PrivateKey) throws -> Stanza {
        let share = ephemeral.publicKey.compressedRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        let key = Age.hkdf(shared, salt: share + publicKey.compressedRepresentation, info: DeviceStanza.info)
        return Stanza(type: DeviceStanza.type, args: [DeviceStanza.tag(publicKey), RawBase64.encode(share)],
                      body: try Age.seal(fileKey, key: key))
    }
}

struct DeviceIdentity: AgeIdentity {
    /// Opaque blob from the Secure Enclave: usable only on this Mac's enclave.
    let keyData: Data
    let publicKey: P256.KeyAgreement.PublicKey
    var reason = "открыть документ из архива"
    /// A context already confirmed by the person: several files open with one Touch ID.
    var context: LAContext?

    /// A new key in the Secure Enclave. Every key agreement asks for Touch ID or the login password.
    static func create() throws -> DeviceIdentity {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        return DeviceIdentity(keyData: key.dataRepresentation, publicKey: key.publicKey)
    }

    func unwrap(stanzas: [Stanza]) throws -> Data? {
        let myTag = DeviceStanza.tag(publicKey)
        for s in stanzas where s.type == DeviceStanza.type {
            guard s.args.count == 2, s.args[0] == myTag else { continue }
            guard let shareData = RawBase64.decode(s.args[1]), s.body.count == 32,
                  let share = try? P256.KeyAgreement.PublicKey(compressedRepresentation: shareData) else {
                throw AgeError.malformed("bad device stanza")
            }
            let context = self.context ?? LAContext()
            if self.context == nil { context.localizedReason = reason }
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: keyData, authenticationContext: context)
            // The Touch ID prompt appears here.
            let shared = try key.sharedSecretFromKeyAgreement(with: share).withUnsafeBytes { Data($0) }
            let wrapKey = Age.hkdf(shared, salt: shareData + publicKey.compressedRepresentation, info: DeviceStanza.info)
            if let fileKey = try? Age.open(s.body, key: wrapKey) { return fileKey }
        }
        return nil
    }
}
