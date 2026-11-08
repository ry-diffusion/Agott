import Contacts
import CoreLocation
import Foundation
import FoundationModels
import MapKit
import NaturalLanguage
import Translation

// Tools built on Apple's own frameworks: MapKit for places and routes,
// Translation for languages (on this Mac), Contacts for the people in the
// address book, Core Location for where the user is.

/// Where the user is now.
nonisolated struct WhereAmITool: Tool {
    let name = "where_am_i"
    let description = """
    Where the user is right now (city and street, from this Mac's location). Use it before answering \
    anything about "here", "near me", the local time or weather, or to search places around them.
    """

    @Generable
    struct Arguments {}

    @concurrent func call(arguments: Arguments) async throws -> String {
        let place = await MainActor.run { () -> Whereabouts.Place? in
            Whereabouts.shared.refresh()
            return Whereabouts.shared.place
        }
        guard let place else {
            return "The exact location is not known (Location Services is off for Agott). The time zone says \(Whereabouts.timeZoneCity)."
        }
        var line = "\(place.city)"
        if let address = place.address { line += " — near \(address)" }
        line += String(format: " (%.4f, %.4f; as of %@)", place.latitude, place.longitude,
                       place.date.formatted(.dateTime.hour().minute()))
        return line
    }
}

/// Places from Apple Maps, around the user or somewhere named.
nonisolated struct AppleMapsSearchTool: Tool {
    let name = "apple_maps_search"
    let description = """
    Search Apple Maps for places: restaurants, cafés, shops, pharmacies, addresses, landmarks. Around the \
    user by default, or around a place you name. Returns name, kind, address, distance, phone and website. \
    Prefer this to nearby_places; use nearby_places when Apple Maps finds nothing.
    """

    @Generable
    struct Arguments {
        @Guide(description: "What to look for, in the user's words: \"padaria\", \"farmácia 24h\", \"Starbucks\", an address")
        var query: String
        @Guide(description: "Where to look around, as a place name with the city; empty for around the user")
        var near: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let origin: CLLocation
        if arguments.near.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let here = await MainActor.run(body: { Whereabouts.shared.coordinate }) else {
                return "The user's location is not known. Ask where, or name a place in `near`."
            }
            origin = CLLocation(latitude: here.latitude, longitude: here.longitude)
        } else {
            guard let request = MKGeocodingRequest(addressString: arguments.near),
                  let found = try? await request.mapItems.first else {
                return "Apple Maps could not find \(arguments.near)."
            }
            origin = found.location
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = arguments.query
        request.region = MKCoordinateRegion(center: origin.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
        do {
            let response = try await MKLocalSearch(request: request).start()
            let items = response.mapItems
                .sorted { $0.location.distance(from: origin) < $1.location.distance(from: origin) }
                .prefix(8)
            guard !items.isEmpty else { return "Apple Maps found nothing for \(arguments.query) there." }
            return items.enumerated().map { index, item in
                var parts = ["\(index + 1). \(item.name ?? arguments.query)"]
                if let category = item.pointOfInterestCategory?.rawValue.replacingOccurrences(of: "MKPOICategory", with: "") {
                    parts.append(category)
                }
                let metres = Int(item.location.distance(from: origin))
                parts.append(metres < 1000 ? "\(metres) m" : String(format: "%.1f km", Double(metres) / 1000))
                if let address = item.address?.shortAddress ?? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) {
                    parts.append(address)
                }
                if let phone = item.phoneNumber { parts.append(phone) }
                if let url = item.url { parts.append(url.absoluteString) }
                return parts.joined(separator: " — ")
            }.joined(separator: "\n")
        } catch {
            return "Apple Maps did not answer (\(error.localizedDescription))."
        }
    }
}

/// How long it takes to get somewhere.
nonisolated struct TravelTimeTool: Tool {
    let name = "travel_time"
    let description = """
    How long it takes to get somewhere with Apple Maps, by car, on foot or by public transport, from where \
    the user is (or a place you name): travel time, distance and arrival time.
    """

    @Generable
    enum Mode: String { case driving, walking, transit }

    @Generable
    struct Arguments {
        @Guide(description: "Where to go: a place name or address, with the city")
        var to: String
        @Guide(description: "Where from; empty for where the user is now")
        var from: String
        var mode: Mode
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        func item(_ text: String) async -> MKMapItem? {
            guard let request = MKGeocodingRequest(addressString: text) else { return nil }
            return try? await request.mapItems.first
        }
        let source: MKMapItem
        if arguments.from.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let here = await MainActor.run(body: { Whereabouts.shared.coordinate }) else {
                return "The user's location is not known; ask where they are leaving from."
            }
            source = MKMapItem(location: CLLocation(latitude: here.latitude, longitude: here.longitude), address: nil)
        } else {
            guard let found = await item(arguments.from) else { return "Apple Maps could not find \(arguments.from)." }
            source = found
        }
        guard let destination = await item(arguments.to) else { return "Apple Maps could not find \(arguments.to)." }
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = switch arguments.mode {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            let minutes = Int((eta.expectedTravelTime / 60).rounded())
            let duration = minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
            return "\(duration), \(String(format: "%.1f", eta.distance / 1000)) km by \(arguments.mode.rawValue); leaving now you arrive around \(eta.expectedArrivalDate.formatted(.dateTime.hour().minute()))."
        } catch {
            return "Apple Maps has no \(arguments.mode.rawValue) route there (\(error.localizedDescription))."
        }
    }
}

/// Translation on this Mac, with Apple's models.
nonisolated struct TranslateTool: Tool {
    let name = "translate"
    let description = """
    Translate text on this Mac with Apple's Translation (private, offline once the languages are downloaded). \
    Use it for messages, menus, signs or documents in another language.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The text to translate")
        var text: String
        @Guide(description: "The language to translate into, as a code: pt-BR, en, es, fr, de, it, ja, ko, zh-Hans…")
        var target: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(arguments.text)
        guard let detected = recognizer.dominantLanguage else { return "Could not tell which language that is." }
        let source = Locale.Language(identifier: detected.rawValue)
        let target = Locale.Language(identifier: arguments.target)
        let status = await LanguageAvailability().status(from: source, to: target)
        switch status {
        case .installed:
            do {
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(arguments.text)
                return response.targetText
            } catch {
                return "Translation failed (\(error.localizedDescription)). Translate it yourself and say so."
            }
        case .supported:
            return "The \(detected.rawValue) → \(arguments.target) languages are not downloaded on this Mac (System Settings → General → Language & Region → Translation Languages). Translate it yourself and mention that."
        default:
            return "Apple Translation does not support \(detected.rawValue) → \(arguments.target). Translate it yourself."
        }
    }
}

/// A person from the address book: phones, emails, birthday, work.
nonisolated struct ContactInfoTool: Tool {
    let name = "contact_info"
    let description = """
    Look someone up in the user's Contacts: phone numbers, email, birthday, company and city. Use it when \
    they ask for someone's number, email or birthday.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The person's name, as the user says it")
        var name: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            return "Agott has no access to Contacts (System Settings → Privacy & Security → Contacts)."
        }
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: arguments.name)
        guard let people = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys), !people.isEmpty else {
            return "No one called \(arguments.name) in Contacts."
        }
        return people.prefix(4).map { person in
            var lines = [CNContactFormatter.string(from: person, style: .fullName) ?? arguments.name]
            if !person.nickname.isEmpty { lines.append("nickname: \(person.nickname)") }
            if !person.organizationName.isEmpty { lines.append("works at: \(person.organizationName)") }
            for phone in person.phoneNumbers.prefix(3) { lines.append("phone: \(phone.value.stringValue)") }
            for email in person.emailAddresses.prefix(2) { lines.append("email: \(email.value)") }
            if let birthday = person.birthday, let month = birthday.month, let day = birthday.day {
                lines.append("birthday: \(day)/\(month)" + (birthday.year.map { "/\($0)" } ?? ""))
            }
            if let city = person.postalAddresses.first?.value.city, !city.isEmpty { lines.append("city: \(city)") }
            return lines.joined(separator: "\n  ")
        }.joined(separator: "\n")
    }
}
