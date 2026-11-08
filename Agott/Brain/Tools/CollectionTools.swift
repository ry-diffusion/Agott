import Foundation
import FoundationModels

/// Shows things as things: a ranking with covers, a grid with posters.
nonisolated struct ShowListTool: Tool {
    let name = "show_list"
    let description = """
    Show a visual list in the conversation when the answer is a set of things people recognise by their \
    picture: a ranking of songs or albums, films or series to watch, books, apps, podcasts, places. Pictures \
    are found by name when you have none, so give real titles and, for songs and albums, the artist as subtitle.
    """

    @Generable
    struct Arguments {
        var title: String
        @Guide(description: "Optional short note under the title, e.g. the period or source")
        var subtitle: String?
        @Guide(description: "ranking: numbered rows, best first. grid: tiles, no order.")
        var style: Style
        @Guide(description: "What the items are, so the right pictures are found")
        var kind: Kind
        @Guide(description: "The items, in order", .maximumCount(25))
        var items: [Item]

        @Generable
        enum Style { case ranking, grid }

        @Generable
        enum Kind { case song, album, artist, movie, show, book, app, podcast, place, other }

        @Generable
        struct Item {
            var title: String
            @Guide(description: "The artist, author, director or a short description")
            var subtitle: String?
            @Guide(description: "A short fact on the right: plays, a rating, a year, a price")
            var detail: String?
            @Guide(description: "An image URL you already have from a tool; leave empty to have one found")
            var imageURL: String?
            @Guide(description: "A link to open the item, when you have one")
            var link: String?
        }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        let kind = "\(arguments.kind)"
        let items = await ArtworkLookup.fill(arguments.items.map { item in
            Card.Collection.Item(title: item.title, subtitle: item.subtitle, detail: item.detail,
                                 image: item.imageURL.flatMap(URL.init(string:)), link: item.link.flatMap(URL.init(string:)))
        }, kind: kind)
        guard !items.isEmpty else { return "A list needs at least one item." }
        await CardBus.post(.collection(.init(
            title: arguments.title, subtitle: arguments.subtitle,
            style: arguments.style == .grid ? .grid : .ranking, kind: kind, items: items)))
        return "The list is on screen with pictures. Say in a sentence what stands out; do not list the items again."
    }
}

/// Your most played on Spotify, as a ranking with the covers.
nonisolated struct SpotifyTopTool: Tool {
    let name = "spotify_top"
    let description = """
    The user's most played tracks or artists on Spotify, shown as a ranking with covers. Use it for "my top \
    songs", "what I listened to most this month", "my favourite artists". Needs Spotify connected in Settings.
    """

    @Generable
    struct Arguments {
        @Guide(description: "tracks or artists")
        var what: What
        @Guide(description: "weeks: about the last 4 weeks. months: about 6 months. years: all time")
        var period: Period
        @Guide(description: "How many, 5 to 50", .range(5...50))
        var count: Int

        @Generable
        enum What { case tracks, artists }

        @Generable
        enum Period { case weeks, months, years }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard await SpotifyAccount.shared.isConnected else {
            return "Spotify is not connected. Tell the user they can connect it in Settings → Connections."
        }
        let range = switch arguments.period {
        case .weeks: "short_term"
        case .months: "medium_term"
        case .years: "long_term"
        }
        let artists = arguments.what == .artists
        let top = try await SpotifyAccount.shared.top(artists: artists, range: range, limit: arguments.count)
        guard !top.isEmpty else { return "Spotify has no top \(artists ? "artists" : "tracks") for that period yet." }
        let period = switch arguments.period {
        case .weeks: String(localized: "Last 4 weeks")
        case .months: String(localized: "Last 6 months")
        case .years: String(localized: "All time")
        }
        await CardBus.post(.collection(.init(
            title: artists ? String(localized: "Your top artists") : String(localized: "Your top songs"),
            subtitle: "Spotify · \(period)", style: .ranking, kind: artists ? "artist" : "song",
            items: top.map { .init(title: $0.title, subtitle: $0.subtitle.isEmpty ? nil : $0.subtitle, image: $0.image, link: $0.link) })))
        let lines = top.enumerated().map { "\($0.offset + 1). \($0.element.title)" + ($0.element.subtitle.isEmpty ? "" : " — \($0.element.subtitle)") }
        return "The ranking is already on screen with covers: do not call show_list for it and do not list it again. " +
            "For you to comment on in a sentence or two:\n" + lines.joined(separator: "\n")
    }
}

/// Finds a picture for something by its name: covers from the iTunes
/// catalogue, posters from IMDb. Nothing for places and the rest.
nonisolated enum ArtworkLookup {
    /// Fills in missing pictures, all at once.
    static func fill(_ items: [Card.Collection.Item], kind: String) async -> [Card.Collection.Item] {
        await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, item) in items.enumerated() where item.image == nil {
                group.addTask { (index, await image(kind: kind, title: item.title, subtitle: item.subtitle)) }
            }
            var filled = items
            for await (index, url) in group { filled[index].image = url }
            return filled
        }
    }

    static func image(kind: String, title: String, subtitle: String?) async -> URL? {
        switch kind {
        case "song": await itunes(term: title, artist: subtitle, media: "music", entity: "song")
        case "album": await itunes(term: title, artist: subtitle, media: "music", entity: "album")
        case "artist": await itunes(term: title, artist: nil, media: "music", entity: "album")
        case "book": await itunes(term: title, artist: subtitle, media: "ebook", entity: "ebook")
        case "app": await itunes(term: title, artist: nil, media: "software", entity: "software")
        case "podcast": await itunes(term: title, artist: nil, media: "podcast", entity: "podcast")
        case "movie", "show": await imdb(title)
        default: nil
        }
    }

    private static func itunes(term: String, artist: String?, media: String, entity: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "term", value: [term, artist].compactMap { $0 }.joined(separator: " ")),
            .init(name: "media", value: media), .init(name: "entity", value: entity),
            .init(name: "limit", value: "1"), .init(name: "country", value: "BR"),
        ]
        guard let url = components.url, let json = await fetch(url),
              let first = (json["results"] as? [[String: Any]])?.first else { return nil }
        let art = (first["artworkUrl512"] ?? first["artworkUrl600"] ?? first["artworkUrl100"]) as? String
        // The catalogue serves any size; ask for one that stays sharp.
        return art.map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }.flatMap(URL.init(string:))
    }

    private static func imdb(_ title: String) async -> URL? {
        let path = title.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/x/\(path).json"),
              let json = await fetch(url),
              let first = (json["d"] as? [[String: Any]])?.first(where: { ($0["id"] as? String)?.hasPrefix("tt") == true }),
              let image = (first["i"] as? [String: Any])?["imageUrl"] as? String else { return nil }
        return URL(string: image)
    }

    private static func fetch(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(HTMLText.browserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
