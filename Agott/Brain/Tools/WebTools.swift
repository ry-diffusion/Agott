import Foundation
import FoundationModels

/// Plain HTML, turned into text a model can read.
nonisolated enum HTMLText {
    static func decode(_ text: String) -> String {
        var result = text
        for (entity, value) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities: &#233; and &#xE9;
        let pattern = /&#(x?)([0-9a-fA-F]+);/
        result = result.replacing(pattern) { match in
            let radix = match.1.isEmpty ? 10 : 16
            guard let code = UInt32(match.2, radix: radix), let scalar = Unicode.Scalar(code) else { return "" }
            return String(Character(scalar))
        }
        return result
    }

    /// Visible text of a page: no scripts, styles or tags; line breaks kept.
    static func text(_ html: String) -> String {
        var page = html
        page = page.replacing(/(?is)<(script|style|noscript|svg|head)[^>]*>.*?<\/\1>/, with: " ")
        page = page.replacing(/(?i)<br\s*\/?>|<\/(p|div|li|h[1-6]|tr|section|article)>/, with: "\n")
        page = page.replacing(/<[^>]+>/, with: " ")
        page = decode(page)
        page = page.replacing(/[ \t]+/, with: " ")
        page = page.replacing(/\n\s*\n+/, with: "\n\n")
        return page.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Safari's own. DuckDuckGo answers an unknown browser with an empty page.
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("pt-BR,pt;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Searching the web through DuckDuckGo's plain HTML page.
nonisolated enum WebSearch {
    struct Result: Sendable, Hashable {
        var title: String
        var url: String
        var snippet: String
    }

    static func search(_ query: String, limit: Int = 6) async throws -> [Result] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [.init(name: "q", value: query), .init(name: "kl", value: "br-pt")]
        let html = try await HTMLText.fetch(components.url!)
        return parse(html, limit: limit)
    }

    /// Each result is an `a.result__a` (title and a redirect link holding the
    /// real address in `uddg`) followed by an `a.result__snippet`.
    static func parse(_ html: String, limit: Int) -> [Result] {
        let links = html.matches(of: /class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/.dotMatchesNewlines())
        let snippets = html.matches(of: /class="result__snippet"[^>]*>(.*?)<\/a>/.dotMatchesNewlines())
        var results: [Result] = []
        for (index, link) in links.enumerated() {
            var address = HTMLText.decode(String(link.1))
            if let components = URLComponents(string: address.hasPrefix("//") ? "https:" + address : address),
               let real = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                address = real
            }
            // Ads point back into DuckDuckGo; skip them.
            guard !address.contains("duckduckgo.com/y.js") else { continue }
            let snippet = index < snippets.count ? HTMLText.text(String(snippets[index].1)) : ""
            results.append(Result(title: HTMLText.text(String(link.2)), url: address, snippet: snippet))
            if results.count == limit { break }
        }
        return results
    }
}

nonisolated struct WebSearchTool: Tool {
    let name = "web_search"
    let description = """
    Search the web for anything current or factual you do not know: news, places, prices, facts, how-tos. \
    Returns titles, links and snippets; use read_web_page to read one in full. Mention where you found things.
    """

    @Generable
    struct Arguments {
        @Guide(description: "What to search for, as you would type it into a search engine")
        var query: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        do {
            let results = try await WebSearch.search(arguments.query)
            guard !results.isEmpty else { return "No results for \(arguments.query)." }
            return results.enumerated().map { index, result in
                "\(index + 1). \(result.title) — \(result.url)\n   \(result.snippet)"
            }.joined(separator: "\n")
        } catch {
            return "The search did not work (\(error.localizedDescription)). Answer from what you know and say so."
        }
    }
}

nonisolated struct ReadWebPageTool: Tool {
    let name = "read_web_page"
    let description = "Read the text of a web page, for example one found with web_search."

    @Generable
    struct Arguments {
        @Guide(description: "The full http or https address")
        var url: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard let url = URL(string: arguments.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "That is not a web address."
        }
        do {
            let text = HTMLText.text(try await HTMLText.fetch(url))
            return text.isEmpty ? "The page has no readable text." : String(text.prefix(12_000))
        } catch {
            return "Could not open the page (\(error.localizedDescription))."
        }
    }
}
