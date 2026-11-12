import CryptoKit
import Foundation
import Security

/// Where a device syncs, and the key that opens what it syncs. Kept in the
/// device's Keychain; the passphrase itself is never stored.
nonisolated struct SyncAccount: Codable, Sendable, Equatable {
    var url: URL
    var token: String
    var master: Data

    var keys: SyncKeys? { SyncKeys(masterData: master) }

    private static let service = "br.com.zesmoi.Agott.sync"
    private static let account = "sync-account"

    static func load() -> SyncAccount? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(SyncAccount.self, from: data)
    }

    /// Saves it, or forgets it with nil.
    static func save(_ value: SyncAccount?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = try? JSONEncoder().encode(value) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// The salt and rounds, in the clear on the Worker, and a sealed known value.
nonisolated struct SyncMeta: Codable, Sendable, Equatable {
    var kdf: String
    var salt: String
    var rounds: Int
    var check: String
}

/// A record as the Worker keeps it: an opaque id and sealed bytes.
nonisolated struct SealedRecord: Codable, Sendable, Equatable {
    var id: String
    var version: Int
    var seq: Int
    var data: String?
}

nonisolated enum SyncError: LocalizedError {
    case unauthorized
    case server(Int, String)
    case notAWorker

    var errorDescription: String? {
        switch self {
        case .unauthorized: String(localized: "The Worker did not accept this token.")
        case .server(let status, let message): String(localized: "The Worker answered \(status): \(message)")
        case .notAWorker: String(localized: "That address is not an Agott sync Worker.")
        }
    }
}

/// Talks to the sync Worker. Knows nothing of what is inside the records.
nonisolated struct SyncClient: Sendable {
    let url: URL
    let token: String

    enum Put: Sendable {
        case stored(SealedRecord)
        /// Someone else wrote it first; here is theirs (nil if it is gone).
        case conflict(SealedRecord?)
    }

    struct Page: Codable, Sendable {
        var records: [SealedRecord]
        var cursor: Int
        var more: Bool
    }

    func health() async throws {
        struct Health: Decodable { var service: String }
        let (data, response) = try await send("GET", "v1/health", auth: false)
        guard response.statusCode == 200, (try? JSONDecoder().decode(Health.self, from: data))?.service == "agott-sync" else {
            throw SyncError.notAWorker
        }
    }

    func meta() async throws -> SyncMeta? {
        let (data, response) = try await send("GET", "v1/meta")
        if response.statusCode == 404 { return nil }
        try check(response, data)
        return try JSONDecoder().decode(SyncMeta.self, from: data)
    }

    /// Sets the meta if there is none; returns the one that stands.
    func putMeta(_ meta: SyncMeta) async throws -> SyncMeta {
        let (data, response) = try await send("PUT", "v1/meta", body: try JSONEncoder().encode(meta))
        guard [200, 201, 409].contains(response.statusCode) else { try check(response, data); throw SyncError.server(response.statusCode, "") }
        return try JSONDecoder().decode(SyncMeta.self, from: data)
    }

    func changes(since: Int) async throws -> Page {
        let (data, response) = try await send("GET", "v1/records?since=\(since)")
        try check(response, data)
        return try JSONDecoder().decode(Page.self, from: data)
    }

    func put(id: String, data sealed: String, base: Int) async throws -> Put {
        struct Body: Encodable { var data: String; var base: Int }
        struct Conflict: Decodable { var current: SealedRecord? }
        let (data, response) = try await send("PUT", "v1/records/\(id)", body: try JSONEncoder().encode(Body(data: sealed, base: base)))
        if response.statusCode == 409 { return .conflict(try JSONDecoder().decode(Conflict.self, from: data).current) }
        try check(response, data)
        return .stored(try JSONDecoder().decode(SealedRecord.self, from: data))
    }

    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw SyncError.unauthorized
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            throw SyncError.server(response.statusCode, message)
        }
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let target = URL(string: base + "/" + path) else {
            throw SyncError.notAWorker
        }
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = method
        if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.notAWorker }
        return (data, http)
    }
}

nonisolated enum SyncSetup {
    /// Joins (or starts) the vault behind this Worker and token with the
    /// passphrase: the first device sets the salt; the others must type the
    /// same passphrase, or they are told so here.
    static func connect(url: URL, token: String, passphrase: String) async throws -> SyncAccount {
        let client = SyncClient(url: url, token: token)
        try await client.health()
        var meta = try await client.meta()
        if meta == nil {
            let salt = SyncKeys.newSalt()
            let master = SyncKeys.master(passphrase: passphrase, salt: salt)
            let proposed = SyncMeta(kdf: "pbkdf2-sha256", salt: salt.base64URL, rounds: SyncKeys.rounds,
                                    check: try SyncKeys(master: master).check())
            meta = try await client.putMeta(proposed)
            if meta == proposed { return SyncAccount(url: url, token: token, master: master.withUnsafeBytes { Data($0) }) }
        }
        guard let meta, meta.kdf == "pbkdf2-sha256", let salt = Data(base64URL: meta.salt) else { throw SyncError.notAWorker }
        let keys = SyncKeys(master: SyncKeys.master(passphrase: passphrase, salt: salt, rounds: meta.rounds))
        guard keys.verify(check: meta.check) else { throw SyncCryptoError.wrongKey }
        return SyncAccount(url: url, token: token, master: keys.masterData)
    }
}
