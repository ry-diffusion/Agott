import Foundation
import FoundationModels

/// Films and series from IMDb, in Portuguese when IMDb has it: its search
/// suggestions find the title, the GraphQL API behind imdb.com gives the
/// rest (rating, plot, genres, cast). For the user's own, personal use, as
/// IMDb allows for this API.
nonisolated enum IMDb {
    struct Match: Sendable {
        var id: String
        var title: String
        var year: Int?
        var kind: String
        var cast: String
    }

    static func search(_ query: String) async throws -> [Match] {
        let path = query.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        let url = URL(string: "https://v3.sg.media-imdb.com/suggestion/x/\(path).json")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(HTMLText.browserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = object?["d"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String, id.hasPrefix("tt") else { return nil }
            return Match(id: id, title: item["l"] as? String ?? "", year: item["y"] as? Int,
                         kind: item["q"] as? String ?? "", cast: item["s"] as? String ?? "")
        }
    }

    static let detailsQuery = """
    query($id: ID!) { title(id: $id) { titleText { text } originalTitleText { text } titleType { text } \
    releaseYear { year endYear } ratingsSummary { aggregateRating voteCount } metacritic { metascore { score } } \
    plot { plotText { plainText } } genres { genres { text } } runtime { seconds } certificate { rating } \
    episodes { seasons { number } } \
    principalCredits { category { text } credits(limit: 5) { name { nameText { text } } } } } }
    """

    static func details(_ id: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://caching.graphql.imdb.com/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(HTMLText.browserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.imdb.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.imdb.com/", forHTTPHeaderField: "Referer")
        let portuguese = Persona.prefersPortuguese
        request.setValue(portuguese ? "BR" : "US", forHTTPHeaderField: "x-imdb-user-country")
        request.setValue(portuguese ? "pt-BR" : "en-US", forHTTPHeaderField: "x-imdb-user-language")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": detailsQuery, "variables": ["id": id]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["data"] as? [String: Any])?["title"] as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return render(title, id: id)
    }

    static func render(_ title: [String: Any], id: String) -> String {
        func text(_ path: String...) -> Any? {
            var value: Any? = title
            for key in path { value = (value as? [String: Any])?[key] }
            return value
        }
        var lines: [String] = []
        let name = text("titleText", "text") as? String ?? ""
        let original = text("originalTitleText", "text") as? String
        var head = name
        if let original, original != name { head += " (\(original))" }
        if let kind = text("titleType", "text") as? String { head += ", \(kind)" }
        if let year = text("releaseYear", "year") as? Int {
            let end = text("releaseYear", "endYear") as? Int
            head += ", \(year)\(end.map { "–\($0)" } ?? "")"
        }
        lines.append(head)
        if let rating = text("ratingsSummary", "aggregateRating") as? Double {
            let votes = text("ratingsSummary", "voteCount") as? Int ?? 0
            var line = "IMDb rating \(rating)/10 (\(votes.formatted()) votes)"
            if let meta = text("metacritic", "metascore", "score") as? Int { line += ", Metacritic \(meta)" }
            lines.append(line)
        }
        if let genres = text("genres", "genres") as? [[String: Any]], !genres.isEmpty {
            lines.append("Genres: " + genres.compactMap { $0["text"] as? String }.joined(separator: ", "))
        }
        var facts: [String] = []
        if let seconds = text("runtime", "seconds") as? Int { facts.append("\(seconds / 60) min") }
        if let rating = text("certificate", "rating") as? String { facts.append("rated \(rating)") }
        if let seasons = text("episodes", "seasons") as? [Any], !seasons.isEmpty { facts.append("\(seasons.count) seasons") }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        if let plot = text("plot", "plotText", "plainText") as? String { lines.append("Plot: \(plot)") }
        for credit in title["principalCredits"] as? [[String: Any]] ?? [] {
            let role = (credit["category"] as? [String: Any])?["text"] as? String ?? ""
            let names = (credit["credits"] as? [[String: Any]] ?? []).compactMap {
                (($0["name"] as? [String: Any])?["nameText"] as? [String: Any])?["text"] as? String
            }
            if !names.isEmpty { lines.append("\(role): \(names.joined(separator: ", "))") }
        }
        lines.append("https://www.imdb.com/title/\(id)/")
        return lines.joined(separator: "\n")
    }
}

nonisolated struct MovieInfoTool: Tool {
    let name = "movie_info"
    let description = """
    Look up a film or series on IMDb: rating, year, genres, plot, length, seasons, creators and cast. \
    Use it for recommendations, "is it good?", "who is in it?" and to know what someone is watching.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The title, in any language (\"O Mentalista\", \"The Mentalist\")")
        var title: String
        @Guide(description: "The release year when known, otherwise 0")
        var year: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        do {
            let matches = try await IMDb.search(arguments.title)
            guard !matches.isEmpty else { return "IMDb has nothing called \(arguments.title)." }
            let chosen = matches.first { arguments.year > 0 && $0.year == arguments.year } ?? matches[0]
            var text = try await IMDb.details(chosen.id)
            let others = matches.filter { $0.id != chosen.id }.prefix(3)
            if !others.isEmpty {
                text += "\nOther matches: " + others.map {
                    "\($0.title)\($0.year.map { " (\($0))" } ?? "") \($0.kind)"
                }.joined(separator: "; ")
            }
            return text
        } catch {
            return "IMDb did not answer (\(error.localizedDescription))."
        }
    }
}
