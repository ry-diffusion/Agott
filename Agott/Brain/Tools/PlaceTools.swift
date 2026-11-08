import CoreLocation
import Foundation
import FoundationModels

/// Places from OpenStreetMap: Nominatim finds an address or a named place,
/// Overpass lists what is around it (bakeries, pharmacies, bars…).
///
/// Both are free community services: one request at a time, an honest
/// User-Agent, no bulk lookups.
nonisolated enum OpenStreetMap {
    static let agent = "Agott/1.0 (personal assistant for macOS)"

    struct Place: Sendable {
        var name: String
        var kind: String
        var address: String
        var latitude: Double
        var longitude: Double
        var hours: String?
        var website: String?
        var phone: String?
        var link: String
    }

    static func get(_ url: URL, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("pt-BR,pt;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Addresses and named places matching `query`, best first.
    /// `within` limits it to a box (west, north, east, south), for "what is near".
    static func search(_ query: String, limit: Int = 5, within box: [Double]? = nil) async throws -> [Place] {
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        components.queryItems = [
            .init(name: "q", value: query), .init(name: "format", value: "jsonv2"),
            .init(name: "limit", value: String(limit)), .init(name: "addressdetails", value: "1"),
            .init(name: "extratags", value: "1"), .init(name: "accept-language", value: "pt-BR"),
        ]
        if let box {
            components.queryItems! += [.init(name: "viewbox", value: box.map { String($0) }.joined(separator: ",")),
                                       .init(name: "bounded", value: "1")]
        }
        let data = try await get(components.url!)
        let items = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let lat = Double(item["lat"] as? String ?? ""), let lon = Double(item["lon"] as? String ?? "") else { return nil }
            let extra = item["extratags"] as? [String: String] ?? [:]  // null when it has none
            let type = item["osm_type"] as? String ?? "node"
            let id = (item["osm_id"] as? NSNumber)?.stringValue ?? ""
            return Place(
                name: item["name"] as? String ?? "",
                kind: "\(item["category"] as? String ?? "") \(item["type"] as? String ?? "")".trimmingCharacters(in: .whitespaces),
                address: item["display_name"] as? String ?? "",
                latitude: lat, longitude: lon,
                hours: extra["opening_hours"], website: extra["website"] ?? extra["contact:website"],
                phone: extra["phone"] ?? extra["contact:phone"],
                link: "https://www.openstreetmap.org/\(type)/\(id)")
        }
    }

    /// What of a kind is within `radius` metres of a point, closest first.
    /// `kind` is an OpenStreetMap value ("bakery", "pharmacy", "cafe") or a
    /// word in the name.
    /// Nominatim first: it answers in under a second and knows most kinds of
    /// place by their English name. Overpass, slower and often busy, only
    /// when Nominatim finds nothing.
    static func nearby(_ kind: String, latitude: Double, longitude: Double, radius: Int, limit: Int = 10) async throws -> [Place] {
        let latSpan = Double(radius) / 111_000
        let lonSpan = latSpan / max(0.2, cos(latitude * .pi / 180))
        let box = [longitude - lonSpan, latitude + latSpan, longitude + lonSpan, latitude - latSpan]
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let found = (try? await search(kind.replacingOccurrences(of: "_", with: " "), limit: 30, within: box)) ?? []
        let close = found
            .filter { !$0.name.isEmpty && origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= Double(radius) * 1.2 }
            .sorted { origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude)) }
        if !close.isEmpty { return Array(close.prefix(limit)) }
        return try await overpass(kind, latitude: latitude, longitude: longitude, radius: radius, limit: limit)
    }

    static func overpass(_ kind: String, latitude: Double, longitude: Double, radius: Int, limit: Int) async throws -> [Place] {
        let value = kind.lowercased().replacingOccurrences(of: "\"", with: "")
        let around = "around:\(radius),\(latitude),\(longitude)"
        let query = """
        [out:json][timeout:12];
        (
          nwr(\(around))["amenity"="\(value)"];
          nwr(\(around))["shop"="\(value)"];
          nwr(\(around))["tourism"="\(value)"];
          nwr(\(around))["leisure"="\(value)"];
          nwr(\(around))["cuisine"="\(value)"];
        );
        out center tags 60;
        """
        var form = URLComponents()
        form.queryItems = [.init(name: "data", value: query)]
        let data = try await get(URL(string: "https://overpass-api.de/api/interpreter")!,
                                 body: Data((form.percentEncodedQuery ?? "").utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let elements = object?["elements"] as? [[String: Any]] ?? []
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        let places: [Place] = elements.compactMap { element in
            let tags = element["tags"] as? [String: String] ?? [:]
            guard let name = tags["name"] else { return nil }
            let center = element["center"] as? [String: Double]
            guard let lat = (element["lat"] as? Double) ?? center?["lat"],
                  let lon = (element["lon"] as? Double) ?? center?["lon"] else { return nil }
            let street = [tags["addr:street"], tags["addr:housenumber"]].compactMap { $0 }.joined(separator: ", ")
            let address = [street, tags["addr:suburb"], tags["addr:city"]].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
            let kind = tags["amenity"] ?? tags["shop"] ?? tags["tourism"] ?? tags["leisure"] ?? value
            return Place(name: name, kind: kind, address: address, latitude: lat, longitude: lon,
                         hours: tags["opening_hours"], website: tags["website"] ?? tags["contact:website"],
                         phone: tags["phone"] ?? tags["contact:phone"],
                         link: "https://www.openstreetmap.org/\(element["type"] as? String ?? "node")/\((element["id"] as? NSNumber)?.stringValue ?? "")")
        }
        var seen = Set<String>()
        return places
            .sorted { origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                < origin.distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude)) }
            .filter { seen.insert($0.name.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    static func describe(_ place: Place, from origin: CLLocation? = nil) -> String {
        var parts = ["\(place.name.isEmpty ? place.address : place.name) (\(place.kind))"]
        if let origin {
            let metres = Int(origin.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)))
            parts.append(metres < 1000 ? "\(metres) m away" : String(format: "%.1f km away", Double(metres) / 1000))
        }
        if !place.address.isEmpty, !place.name.isEmpty { parts.append(place.address) }
        if let hours = place.hours { parts.append("hours: \(hours)") }
        if let phone = place.phone { parts.append("phone: \(phone)") }
        if let website = place.website { parts.append(website) }
        parts.append(String(format: "%.5f, %.5f", place.latitude, place.longitude))
        parts.append(place.link)
        return parts.joined(separator: " — ")
    }
}

nonisolated struct FindPlaceTool: Tool {
    let name = "find_place"
    let description = """
    Find an address, street, neighbourhood, city or named place on OpenStreetMap: where it is, its full \
    address and coordinates. Use nearby_places for "what is around".
    """

    @Generable
    struct Arguments {
        @Guide(description: "The place, as specific as you can: name plus city, or a full address")
        var query: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        do {
            let places = try await OpenStreetMap.search(arguments.query)
            guard !places.isEmpty else { return "OpenStreetMap has nothing for \(arguments.query). Try another spelling or add the city." }
            return places.enumerated().map { "\($0.offset + 1). " + OpenStreetMap.describe($0.element) }
                .joined(separator: "\n") + "\n(Data © OpenStreetMap contributors)"
        } catch {
            return "OpenStreetMap did not answer (\(error.localizedDescription))."
        }
    }
}

nonisolated struct NearbyPlacesTool: Tool {
    let name = "nearby_places"
    let description = """
    List places of a kind near somewhere, from OpenStreetMap, closest first, with hours, phone and website \
    when known: bakeries, pharmacies, cafés, restaurants, bars, supermarkets, ATMs, hospitals, parks…
    """

    @Generable
    struct Arguments {
        @Guide(description: "Where to look around: an address, street, neighbourhood or named place, with the city")
        var near: String
        @Guide(description: "The kind as an OpenStreetMap value in English: bakery, pharmacy, cafe, restaurant, bar, pub, fast_food, supermarket, convenience, atm, bank, hospital, clinic, dentist, gym, park, hotel, fuel, parking, bus_station, cinema, books, clothes. Or a word from the name, like a brand")
        var kind: String
        @Guide(description: "How far to look, in metres", .range(200...5000))
        var radius: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        do {
            guard let center = try await OpenStreetMap.search(arguments.near, limit: 1).first else {
                return "Could not find \(arguments.near) on the map. Ask where exactly, or add the city."
            }
            let places = try await OpenStreetMap.nearby(arguments.kind, latitude: center.latitude, longitude: center.longitude,
                                                        radius: arguments.radius)
            guard !places.isEmpty else {
                return "No \(arguments.kind) within \(arguments.radius) m of \(center.address) on OpenStreetMap. A larger radius may find some."
            }
            let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
            return "Around \(center.address):\n" + places.enumerated().map {
                "\($0.offset + 1). " + OpenStreetMap.describe($0.element, from: origin)
            }.joined(separator: "\n") + "\n(Data © OpenStreetMap contributors)"
        } catch {
            return "OpenStreetMap did not answer (\(error.localizedDescription)). It may be busy; try again in a moment."
        }
    }
}
