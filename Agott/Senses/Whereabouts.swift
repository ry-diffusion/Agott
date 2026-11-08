import CoreLocation
import Foundation
import MapKit

/// Where the user is right now: the city this Mac is in, from Location
/// Services, named by MapKit.
///
/// Without it the model guessed from memories ("you're in England, right?"
/// because of an old exchange-programme chat). With it the instructions say
/// where they are now, and place tools search around them.
///
/// The fix is refreshed at most every half hour and kept, so a question never
/// waits on GPS. Without permission it falls back to the time zone's city.
@MainActor @Observable
final class Whereabouts: NSObject, CLLocationManagerDelegate {
    static let shared = Whereabouts()

    struct Place: Codable, Equatable, Sendable {
        var city: String
        var address: String?
        var latitude: Double
        var longitude: Double
        var date: Date
    }

    private(set) var place: Place?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    private static let storeKey = "whereabouts.place"
    private static let freshFor: TimeInterval = 30 * 60

    override private init() {
        super.init()
        manager.delegate = self
        if let data = UserDefaults.standard.data(forKey: Self.storeKey) {
            place = try? JSONDecoder().decode(Place.self, from: data)
        }
    }

    var isAllowed: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways: true
        #if os(iOS)
        case .authorizedWhenInUse: true
        #endif
        default: false
        }
    }

    /// The line for the model's instructions: where they are and how sure.
    var summary: String {
        if let place {
            let age = Date().timeIntervalSince(place.date)
            let when = age < 3 * 3600 ? "now" : "as of \(place.date.formatted(.dateTime.weekday(.wide).hour().minute()))"
            return "\(place.city) (\(when), from this device's location)"
        }
        return "probably \(Self.timeZoneCity) (from the time zone; the exact location is not known)"
    }

    /// "America/Sao_Paulo" → "Sao Paulo".
    nonisolated static var timeZoneCity: String {
        let identifier = TimeZone.current.identifier
        let city = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return city.replacingOccurrences(of: "_", with: " ")
    }

    /// Asks for permission the first time; afterwards refreshes in the
    /// background when the last fix is old. Never blocks.
    func refresh(force: Bool = false) {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        guard isAllowed, refreshing == nil else { return }
        if !force, let place, Date().timeIntervalSince(place.date) < Self.freshFor { return }
        refreshing = Task { [weak self] in
            defer { self?.refreshing = nil }
            guard let location = await Self.oneFix() else { return }
            let named = await Self.name(location)
            let place = Place(city: named.city, address: named.address,
                              latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, date: .now)
            self?.place = place
            if let data = try? JSONEncoder().encode(place) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        }
    }

    /// Where to search around: the last fix, or nil when unknown.
    var coordinate: CLLocationCoordinate2D? {
        place.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh(force: true) }
    }

    /// The first usable position, or nil after a few seconds.
    private static func oneFix() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "Goiânia, GO, Brasil" and the street address, from MapKit.
    private static func name(_ location: CLLocation) async -> (city: String, address: String?) {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else {
            return (timeZoneCity, nil)
        }
        let city = item.addressRepresentations?.cityWithContext ?? item.name ?? timeZoneCity
        return (city, item.address?.shortAddress)
    }
}
