import CryptoKit
import Foundation
import Observation

/// Your Spotify account, signed in with OAuth2 (authorization code + PKCE).
///
/// You create a Spotify app once at developer.spotify.com, add the redirect
/// URI below, and paste its Client ID; there is no client secret, PKCE
/// proves it is this app. The refresh token lives in the Keychain. With it,
/// Agott sees what you play on any device and your recent listening.
@Observable
final class SpotifyAccount {
    static let shared = SpotifyAccount()

    static let redirectURI = "agott://spotify-callback"
    static let callbackScheme = "agott"
    static let scopes = "user-read-currently-playing user-read-playback-state user-read-recently-played user-top-read"
    private static let refreshAccount = "spotify-refresh-token"

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "spotifyClientID") }
    }
    private(set) var displayName: String?
    private(set) var isConnected: Bool

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var expires = Date.distantPast
    @ObservationIgnored private var verifier = ""

    private init() {
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        isConnected = Keychain.get(Self.refreshAccount) != nil
        displayName = UserDefaults.standard.string(forKey: "spotifyDisplayName")
    }

    // MARK: Sign in

    /// The page to sign in on. Keeps the PKCE verifier for `finish`.
    func authorizeURL() -> URL? {
        guard !clientID.isEmpty else { return nil }
        verifier = Self.randomVerifier()
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(for: verifier)),
            .init(name: "scope", value: Self.scopes),
        ]
        return components.url
    }

    /// Exchanges the code Spotify sent back for tokens.
    func finish(callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw SpotifyError.denied(error) }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw SpotifyError.denied("no code") }
        try await token([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ])
        if let me = try? await get("https://api.spotify.com/v1/me"), let name = me["display_name"] as? String {
            displayName = name
            UserDefaults.standard.set(name, forKey: "spotifyDisplayName")
        }
        isConnected = true
    }

    func signOut() {
        Keychain.set("", for: Self.refreshAccount)
        accessToken = nil
        isConnected = false
        displayName = nil
        UserDefaults.standard.removeObject(forKey: "spotifyDisplayName")
    }

    // MARK: Web API

    struct Current: Sendable {
        var play: Play
        var artwork: URL?
        var isPlaying: Bool
    }

    /// What is playing on any of your devices, or nil.
    func currentlyPlaying() async throws -> Current? {
        guard let json = try await get("https://api.spotify.com/v1/me/player/currently-playing"),
              let item = json["item"] as? [String: Any] else { return nil }
        let (play, artwork) = Self.track(item, at: .now)
        return Current(play: play, artwork: artwork, isPlaying: json["is_playing"] as? Bool ?? false)
    }

    /// Songs you played since `after` (up to 50), oldest first.
    func recentlyPlayed(after: Date) async throws -> [Play] {
        let ms = Int(after.timeIntervalSince1970 * 1000)
        guard let json = try await get("https://api.spotify.com/v1/me/player/recently-played?limit=50&after=\(ms)"),
              let items = json["items"] as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.compactMap { item -> Play? in
            guard let track = item["track"] as? [String: Any], let at = item["played_at"] as? String,
                  let date = iso.date(from: at) ?? ISO8601DateFormatter().date(from: at) else { return nil }
            return Self.track(track, at: date).0
        }
        .sorted { $0.date < $1.date }
    }

    /// One of your most played tracks or artists, with its picture.
    struct TopItem: Sendable {
        var title: String
        var subtitle: String
        var image: URL?
        var link: URL?
    }

    /// Your top tracks or artists over the last four weeks (short_term), six
    /// months (medium_term) or years (long_term).
    func top(artists: Bool, range: String, limit: Int) async throws -> [TopItem] {
        let path = artists ? "artists" : "tracks"
        guard let json = try await get("https://api.spotify.com/v1/me/top/\(path)?time_range=\(range)&limit=\(max(1, min(limit, 50)))"),
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.map { item in
            let link = (item["external_urls"] as? [String: Any])?["spotify"] as? String
            if artists {
                let genres = (item["genres"] as? [String] ?? []).prefix(2).joined(separator: ", ")
                let image = (item["images"] as? [[String: Any]])?.first?["url"] as? String
                return TopItem(title: item["name"] as? String ?? "", subtitle: genres,
                               image: image.flatMap(URL.init(string:)), link: link.flatMap(URL.init(string:)))
            }
            let (play, image) = Self.track(item, at: .now)
            return TopItem(title: play.track, subtitle: play.artist, image: image, link: link.flatMap(URL.init(string:)))
        }
    }

    nonisolated static func track(_ item: [String: Any], at date: Date) -> (Play, URL?) {
        let artists = (item["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let album = item["album"] as? [String: Any] ?? [:]
        let image = (album["images"] as? [[String: Any]])?.first?["url"] as? String
        let play = Play(date: date, track: item["name"] as? String ?? "", artist: artists.joined(separator: ", "),
                        album: album["name"] as? String ?? "", app: "Spotify")
        return (play, image.flatMap(URL.init(string:)))
    }

    private func get(_ url: String) async throws -> [String: Any]? {
        let token = try await validToken()
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return nil }
        if status == 401 { accessToken = nil }
        guard status == 200 else { throw SpotifyError.http(status) }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func validToken() async throws -> String {
        if let accessToken, expires > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = Keychain.get(Self.refreshAccount) else { throw SpotifyError.notConnected }
        try await token(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw SpotifyError.notConnected }
        return accessToken
    }

    private func token(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+:/")
        request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            if form["grant_type"] == "refresh_token" { signOut() }
            throw SpotifyError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        accessToken = access
        expires = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, for: Self.refreshAccount) }
    }

    // MARK: PKCE

    nonisolated static func randomVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in alphabet.randomElement()! })
    }

    nonisolated static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    enum SpotifyError: LocalizedError {
        case notConnected, denied(String), http(Int)
        var errorDescription: String? {
            switch self {
            case .notConnected: String(localized: "Spotify is not connected.")
            case .denied(let reason): String(localized: "Spotify sign-in did not finish (\(reason)).")
            case .http(let code): String(localized: "Spotify answered \(code).")
            }
        }
    }
}
