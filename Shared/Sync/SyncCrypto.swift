import CommonCrypto
import CryptoKit
import Foundation

/// End-to-end encryption for sync: the Worker only ever stores what this
/// seals, and cannot read it, rename it or move it between records.
///
/// - The passphrase the user types becomes a 32-byte master key with
///   PBKDF2-HMAC-SHA256 and a random salt kept (in the clear) on the Worker.
/// - HKDF-SHA256 splits the master into an encryption key and a naming key.
/// - Each record is AES-256-GCM sealed, with its id as associated data.
/// - Record ids are HMAC-SHA256(naming key, the record's real name), so the
///   Worker sees neither names nor dates, and two devices marking the same
///   day done write the same record.
nonisolated struct SyncKeys: Sendable {
    static let rounds = 600_000
    static let format = "v1"

    /// The master key: what a device keeps (in its Keychain) instead of the passphrase.
    let master: SymmetricKey
    private let sealing: SymmetricKey
    private let naming: SymmetricKey

    init(master: SymmetricKey) {
        self.master = master
        let derive = { (info: String) in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("agott-sync".utf8),
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        sealing = derive("agott-sync-v1 seal")
        naming = derive("agott-sync-v1 name")
    }

    init?(masterData: Data) {
        guard masterData.count == 32 else { return nil }
        self.init(master: SymmetricKey(data: masterData))
    }

    var masterData: Data { master.withUnsafeBytes { Data($0) } }

    /// The passphrase stretched. Slow on purpose (about a second on a phone).
    static func master(passphrase: String, salt: Data, rounds: Int = rounds) -> SymmetricKey {
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    &out, out.count)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return SymmetricKey(data: out)
    }

    static func newSalt() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    /// The id the Worker sees for a record called `name` ("routine/…").
    func recordID(_ name: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(name.utf8), using: naming)
        return Data(mac).prefix(24).base64URL
    }

    func seal(_ plaintext: Data, id: String) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: sealing, authenticating: Self.aad(id))
        guard let combined = box.combined else { throw SyncCryptoError.sealFailed }
        return Self.format + "." + combined.base64URL
    }

    func open(_ sealed: String, id: String) throws -> Data {
        let parts = sealed.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0] == Self.format, let combined = Data(base64URL: String(parts[1])) else {
            throw SyncCryptoError.badFormat
        }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: sealing, authenticating: Self.aad(id))
        } catch {
            throw SyncCryptoError.wrongKey
        }
    }

    /// Kept next to the salt, so a wrong passphrase shows at once rather
    /// than as records that will not open.
    func check() throws -> String { try seal(Data("agott".utf8), id: "check") }

    func verify(check: String) -> Bool {
        (try? open(check, id: "check")) == Data("agott".utf8)
    }

    private static func aad(_ id: String) -> Data { Data("agott-sync-v1|\(id)".utf8) }
}

nonisolated enum SyncCryptoError: LocalizedError {
    case sealFailed, badFormat, wrongKey

    var errorDescription: String? {
        switch self {
        case .sealFailed: String(localized: "Could not encrypt.")
        case .badFormat: String(localized: "A synced record is not in a format Agott knows.")
        case .wrongKey: String(localized: "This passphrase does not open your synced data.")
        }
    }
}

nonisolated extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}
