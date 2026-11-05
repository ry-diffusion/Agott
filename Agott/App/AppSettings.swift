import Foundation
import Observation
import Security

nonisolated enum ModelProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    /// DeepSeek V4 Flash (or any model) through OpenCode Go.
    case openCode
    /// Apple's larger model on Private Cloud Compute.
    case privateCloud
    /// Apple's on-device model. Nothing leaves the Mac.
    case onDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openCode: String(localized: "OpenCode Go")
        case .privateCloud: String(localized: "Apple Private Cloud")
        case .onDevice: String(localized: "On this device")
        }
    }

    var detail: String {
        switch self {
        case .openCode: String(localized: "DeepSeek V4.1 Flash through OpenCode Go. The smartest option, and the one that drives the computer best.")
        case .privateCloud: String(localized: "Apple's server model. Private by design, with a daily quota.")
        case .onDevice: String(localized: "Apple Intelligence on your Mac. Fully offline, best for short tasks.")
        }
    }
}

nonisolated enum HoldKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case rightOption, rightCommand, globe, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: String(localized: "Right Option (⌥)")
        case .rightCommand: String(localized: "Right Command (⌘)")
        case .globe: String(localized: "Globe (🌐)")
        case .off: String(localized: "Off")
        }
    }
}

/// Preferences, backed by `UserDefaults`; the API key lives in the Keychain.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var provider: ModelProvider { didSet { save(provider.rawValue, "provider") } }
    var baseURL: String { didSet { save(baseURL, "baseURL") } }
    var modelName: String { didSet { save(modelName, "modelName") } }
    var visionModelName: String { didSet { save(visionModelName, "visionModelName") } }
    var lookWithVision: Bool { didSet { save(lookWithVision, "lookWithVision") } }
    var myName: String { didSet { save(myName, "myName") } }
    var speechLocale: String { didSet { save(speechLocale, "speechLocale") } }
    var askKey: HoldKey { didSet { save(askKey.rawValue, "askKey") } }
    var dictateKey: HoldKey { didSet { save(dictateKey.rawValue, "dictateKey") } }
    var autopilot: Bool { didSet { save(autopilot, "autopilot") } }
    var useScreenContext: Bool { didSet { save(useScreenContext, "useScreenContext") } }
    var enabledSources: Set<MemorySource> {
        didSet { save(enabledSources.map(\.rawValue), "enabledSources") }
    }
    var hasOnboarded: Bool { didSet { save(hasOnboarded, "hasOnboarded") } }
    /// The model that reads your messages to learn about you.
    var learningProvider: ModelProvider { didSet { save(learningProvider.rawValue, "learningProvider") } }
    /// The OpenCode model's context window, in tokens.
    var contextTokens: Int { didSet { save(contextTokens, "contextTokens") } }
    /// Let the model read new moments after every indexing run.
    var autoLearn: Bool { didSet { save(autoLearn, "autoLearn") } }
    /// How much of that window one learning batch may fill.
    var batchFill: Double { didSet { save(batchFill, "batchFill") } }
    /// A paragraph about you, written by Agott from what it has learned and
    /// editable by you. Every conversation starts from it.
    var aboutMe: String { didSet { save(aboutMe, "aboutMe") } }

    var apiKey: String {
        didSet { Keychain.set(apiKey, for: "opencode-api-key") }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        provider = ModelProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openCode
        baseURL = Self.migrated(defaults.string(forKey: "baseURL"), stale: Self.staleURLs, current: Self.defaultBaseURL)
        modelName = Self.migrated(defaults.string(forKey: "modelName"), stale: ["deepseek-v4-flash"], current: Self.defaultModel)
        visionModelName = defaults.string(forKey: "visionModelName") ?? Self.defaultModel
        lookWithVision = defaults.object(forKey: "lookWithVision") as? Bool ?? false
        myName = defaults.string(forKey: "myName") ?? Self.defaultName
        speechLocale = defaults.string(forKey: "speechLocale")
            ?? (Locale.preferredLanguages.first?.hasPrefix("pt") == true ? "pt-BR" : "en-US")
        askKey = HoldKey(rawValue: defaults.string(forKey: "askKey") ?? "") ?? .rightOption
        dictateKey = HoldKey(rawValue: defaults.string(forKey: "dictateKey") ?? "") ?? .off
        autopilot = defaults.bool(forKey: "autopilot")
        useScreenContext = defaults.object(forKey: "useScreenContext") as? Bool ?? true
        enabledSources = Set((defaults.stringArray(forKey: "enabledSources") ?? ["imessage", "whatsapp", "claude"])
            .compactMap(MemorySource.init(rawValue:)))
        hasOnboarded = defaults.bool(forKey: "hasOnboarded")
        learningProvider = ModelProvider(rawValue: defaults.string(forKey: "learningProvider") ?? "") ?? .openCode
        contextTokens = defaults.object(forKey: "contextTokens") as? Int ?? 128_000
        batchFill = defaults.object(forKey: "batchFill") as? Double ?? 0.5
        autoLearn = defaults.object(forKey: "autoLearn") as? Bool ?? true
        aboutMe = defaults.string(forKey: "aboutMe") ?? ""
        apiKey = Keychain.get("opencode-api-key") ?? ""
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    nonisolated static let defaultBaseURL = "https://opencode.ai/inference/go/openai/v1"
    nonisolated static let defaultModel = "deepseek-v4.1-flash"
    nonisolated static let staleURLs = ["https://opencode.ai/zen/go/v1", "https://opencode.ai/zen/go/v1/"]

    /// Earlier builds shipped a wrong endpoint and model id; replace them, but
    /// leave anything the user typed themselves.
    nonisolated private static func migrated(_ saved: String?, stale: [String], current: String) -> String {
        guard let saved, !stale.contains(saved) else { return current }
        return saved
    }

    nonisolated static var defaultName: String {
        #if os(macOS)
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
        #else
        return String(localized: "Me")
        #endif
    }

    /// Readable from any thread, for ingestion running off the main actor.
    nonisolated static var myNameSnapshot: String {
        UserDefaults.standard.string(forKey: "myName") ?? defaultName
    }
}

nonisolated enum Keychain {
    private static let service = "br.com.zesmoi.Agott"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
