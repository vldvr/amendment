import CryptoKit
import Foundation

/// Archive crypto checks for `redakciya-checks archive`: the vectors of spec/archive-format.md, age round trips,
/// tampering, and the recovery words. No Touch ID and no Secure Enclave: the device key is a software P-256 key
/// with the same stanza. `ageCLI` (path to the reference `age`) adds interop with it when it is installed.
public enum ArchiveSelfTest {
    /// Same unwrap as DeviceIdentity, with a key in memory, to test the stanza without a prompt.
    struct SoftDeviceIdentity: AgeIdentity {
        let key: P256.KeyAgreement.PrivateKey
        func unwrap(stanzas: [Stanza]) throws -> Data? {
            for s in stanzas where s.type == DeviceStanza.type && s.args.first == DeviceStanza.tag(key.publicKey) {
                guard let shareData = RawBase64.decode(s.args[1]),
                      let share = try? P256.KeyAgreement.PublicKey(compressedRepresentation: shareData) else { continue }
                let shared = try key.sharedSecretFromKeyAgreement(with: share).withUnsafeBytes { Data($0) }
                let wrap = Age.hkdf(shared, salt: shareData + key.publicKey.compressedRepresentation, info: DeviceStanza.info)
                if let k = try? Age.open(s.body, key: wrap) { return k }
            }
            return nil
        }
    }

    static func hex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    static func random(_ n: Int) -> Data {
        var d = Data(count: n)
        if n > 0 { _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) } }
        return d
    }

    public static func run(ageCLI: String? = nil) -> (checks: Int, failures: [String]) {
        var checks = 0
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what) }
        }

        // spec/archive-format.md, «Ключ восстановления».
        let vectors: [(entropy: String, indices: [Int], secret: String, key: String, recipient: String)] = [
            ("00000000000000000000000000000000", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3],
             "73fe28d013a6fd1e85d6d48938d87c2fd8a3bae68e9e67432727c209066c7e6d",
             "AGE-SECRET-KEY-1W0LZ35QN5M73APWK6JYN3KRU9LV28WHX360XWSE8YLPQJPNV0EKSE84DEU",
             "age17tqzl8248dmxs40zxm2zjstgdqea6rkwzqt80cjuysmp5zm7pcksu4xxq3"),
            ("ffffffffffffffffffffffffffffffff", Array(repeating: 2047, count: 11) + [2037],
             "494db390c3519b488a9633428e89eab2b24e185658be091a830a366e78656806",
             "AGE-SECRET-KEY-1F9XM8YXR2XD53Z5KXDPGAZ02K2EYUXZKTZLQJX5RPGMXU7R9DQRQG3ETYZ",
             "age1kj6z6syx28wvdt0kejlwrw8wu0j5fjd870256cck7kr0lzc9t9msmjr9h8"),
            ("000102030405060708090a0b0c0d0e0f", [0, 64, 1030, 64, 643, 28, 257, 266, 88, 771, 540, 251],
             "018f3428a05089b2e2a13e3c85e1f4963ea32b649b6ece7d9a5771da576b511b",
             "AGE-SECRET-KEY-1QX8NG29Q2ZYM9C4P8C7GTC05JCL2X2MYNDHVULV62ACA54MT2YDSCZD2QX",
             "age13zz8a9f0ctf2uahd93uqcshls357g4jrv4dkuw8f0drw2aknlflq3rnhey"),
            ("25e3587ccf33b770eab4c3fb60ae7044", [303, 214, 249, 1267, 475, 1475, 1366, 1219, 2011, 43, 1248, 1090],
             "6ce54fdc6d07c777e8fffafb7127008f738d42b5e082ddb3b773e900d643c82c",
             "AGE-SECRET-KEY-1DNJ5LHRDQLRH068LLTAHZFCQ3AEC6S44UZPDMVAHW05SP4JREQKQ3JRJV4",
             "age1cffme0jsfxx8m0p69xkfz24z8pxa3t6vfzm9mhc29pkuakmegpeqv7py84"),
        ]
        for v in vectors {
            let e = hex(v.entropy)
            check(Recovery.indices(for: e) == v.indices, "vector \(v.entropy): word numbers")
            let id = Recovery.identity(from: e)
            check(id.privateKey.rawRepresentation == hex(v.secret), "vector \(v.entropy): X25519 secret")
            check(id.string == v.key, "vector \(v.entropy): key string")
            check(id.recipient.string == v.recipient, "vector \(v.entropy): recipient")
        }

        // spec/archive-format.md, «Блок ключа устройства».
        do {
            let device = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex("d0df8d3a169f57465ef5bea5d228419a5822dccdef66995e1535f182173af9a0"))
            let eph = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex("371e39c6c36b0a2b43de7648fe14920d2e546205bf707b141a0bdfb1268cd2ec"))
            check(device.publicKey.compressedRepresentation == hex("0383fa7cf5fa954266649d810e1ec438102ec328c1c7b6501752ae620342eebc66"),
                  "device vector: public key")
            let s = try DeviceRecipient(publicKey: device.publicKey).wrap(fileKey: hex("000102030405060708090a0b0c0d0e0f"), ephemeral: eph)
            check(s.args == ["eEREoA", "Aoz6iXbWiIuACB2lDTY46v0W7X2StBHhWs9zH5EAVmyJ"], "device vector: stanza arguments")
            check(RawBase64.encode(s.body) == "Dmxnr5JJMtrroFqK/py5TJdmL+YHOUh/3Lbs6Ls1CfI", "device vector: stanza body")
            check(try SoftDeviceIdentity(key: device).unwrap(stanzas: [s]) == hex("000102030405060708090a0b0c0d0e0f"),
                  "device vector: unwraps back")
        } catch {
            check(false, "device vector: \(error)")
        }

        let id = X25519Identity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        check(X25519Identity(id.string)?.recipient.string == id.recipient.string, "age identity string round trip")
        let soft = P256.KeyAgreement.PrivateKey()
        let recipients: [AgeRecipient] = [DeviceRecipient(publicKey: soft.publicKey), id.recipient]
        for size in [0, 1, 1000, 65535, 65536, 65537, 200_000] {
            let plain = random(size)
            do {
                let sealed = try Age.encrypt(plain, to: recipients)
                let a = try Age.decrypt(sealed, with: [id])
                let b = try Age.decrypt(sealed, with: [SoftDeviceIdentity(key: soft)])
                check(a == plain && b == plain, "round trip \(size) bytes, both keys")
            } catch {
                check(false, "round trip \(size) bytes: \(error)")
            }
        }
        do {
            let sealed = try Age.encrypt(random(5000), to: recipients)
            var payload = sealed
            payload[payload.count - 20] ^= 1
            check((try? Age.decrypt(payload, with: [id])) == nil, "tampered payload is rejected")
            let header = try Age.parseHeader(sealed)
            var mac = sealed
            mac[header.payloadOffset - 5] ^= 1
            check((try? Age.decrypt(mac, with: [id])) == nil, "tampered header MAC is rejected")
            let stranger = X25519Identity(privateKey: Curve25519.KeyAgreement.PrivateKey())
            check((try? Age.decrypt(sealed, with: [stranger])) == nil, "a stranger's key opens nothing")
        } catch {
            check(false, "tamper tests: \(error)")
        }

        let list = Recovery.list
        check(list.count == 2048 && Set(list.map { $0.prefix(4) }).count == 2048, "word list: 2048 words, unique first four letters")
        check(list.allSatisfy { (4...8).contains($0.count) && !$0.contains("ё") }, "word list: 4 to 8 letters, no ё")
        check(list == list.sorted(), "word list: in alphabetical order")
        let entropy = random(16)
        let words = Recovery.words(for: entropy, list: list)
        check((try? Recovery.entropy(from: words, list: list)) == entropy, "words round trip")
        check((try? Recovery.entropy(from: words.map { String($0.prefix(4)).uppercased() }, list: list)) == entropy,
              "first four letters in capitals are enough")
        var swapped = words
        swapped.swapAt(0, 11)
        if swapped != words { check((try? Recovery.entropy(from: swapped, list: list)) != entropy, "words out of order fail") }

        // The reference age opens our file with the recovery key, and we open its file.
        if let cli = ageCLI {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("redakciya-age-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let keyFile = dir.appendingPathComponent("key.txt"), sealedFile = dir.appendingPathComponent("doc.age")
            let plain = random(70_000)
            do {
                try Data((id.string + "\n").utf8).write(to: keyFile)
                try Age.encrypt(plain, to: recipients).write(to: sealedFile)
                let out = try run(cli, ["-d", "-i", keyFile.path, sealedFile.path])
                check(out == plain, "reference age opens our file by the recovery key")
                let plainFile = dir.appendingPathComponent("plain.bin")
                try plain.write(to: plainFile)
                let theirs = try run(cli, ["-r", id.recipient.string, plainFile.path])
                check(try Age.decrypt(theirs, with: [id]) == plain, "we open a file of the reference age")
            } catch {
                check(false, "reference age: \(error)")
            }
        }
        return (checks, failures)
    }

    static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw AgeError.malformed("\(tool) exited \(p.terminationStatus)") }
        return data
    }
}
