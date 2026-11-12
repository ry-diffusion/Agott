import Contacts
import Foundation

/// Phone numbers and emails to the names you know people by.
///
/// iMessage stores handles, not names, and WhatsApp only has a name for people
/// in your address book or who set a push name. Matching on the last nine
/// digits handles the "+55 11 9…" vs "11 9…" vs "(11) 9…" spread that a
/// Brazilian address book always has.
nonisolated final class ContactBook: @unchecked Sendable {
    private var byPhone: [String: String] = [:]
    private var byEmail: [String: String] = [:]
    private(set) var isLoaded = false

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    func load() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? (contact.nickname.isEmpty ? nil : contact.nickname)
            // A contact saved with only its number has no name to give.
            guard let name, !name.isEmpty, name.contains(where: \.isLetter) else { return }
            for number in contact.phoneNumbers {
                let key = Self.phoneKey(number.value.stringValue)
                if !key.isEmpty { self.byPhone[key] = name }
            }
            for email in contact.emailAddresses {
                self.byEmail[(email.value as String).lowercased()] = name
            }
        }
        isLoaded = true
    }

    /// The last nine digits: enough to be unique, short enough to ignore
    /// country and area code formatting.
    static func phoneKey(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return String(digits.suffix(9))
    }

    func name(forHandle handle: String) -> String? {
        if handle.contains("@") && !handle.hasSuffix("whatsapp.net") && !handle.hasSuffix("g.us") {
            return byEmail[handle.lowercased()]
        }
        let key = Self.phoneKey(handle.components(separatedBy: "@").first ?? handle)
        return key.isEmpty ? nil : byPhone[key]
    }

    /// A name if there is one, otherwise the handle made readable.
    func display(_ handle: String) -> String {
        if let name = name(forHandle: handle) { return name }
        let bare = handle.components(separatedBy: "@").first ?? handle
        if bare.allSatisfy({ $0.isNumber || $0 == "+" }), bare.count > 6 { return "+" + bare.filter(\.isNumber) }
        return bare
    }
}
