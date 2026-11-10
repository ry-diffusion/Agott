import Foundation

/// People inside artifacts. The model writes them as tags (`<e id=12/>`),
/// as everywhere else; the app swaps each tag for the name when the
/// artifact is shown, copied, saved or published, so nobody sees a tag.
///
/// Names come from the artifact's own list first (`Card.Artifact.people`,
/// kept when it was made), then from the directory, for older artifacts.
enum ArtifactNames {
    typealias Mention = Card.Artifact.Mention

    /// Tags as written, and as a page that escaped them: `&lt;e id=12/&gt;`.
    private static var tagPattern: Regex<(Substring, Substring?, Substring?)> {
        /<e\s+id\s*=\s*["']?(\d+)["']?\s*\/?>(?:\s*<\/e>)?|&lt;e\s+id\s*=\s*(?:&quot;|["'])?(\d+)(?:&quot;|["'])?\s*\/?&gt;/
    }

    /// Who a text's tags name, once each, as the directory knows them now.
    static func mentions(in text: String, lookup: (Int64) -> PersonRef?) -> [Mention] {
        var seen = Set<Int64>()
        return text.matches(of: tagPattern).compactMap { match -> Mention? in
            guard let id = (match.1 ?? match.2).flatMap({ Int64($0) }), seen.insert(id).inserted,
                  let ref = lookup(id) else { return nil }
            return Mention(id: id, name: ref.name, isGroup: ref.kind == .group)
        }
    }

    /// How a tag reads: the name, or "Person 12" while names are hidden or
    /// when nobody knows the id.
    static func label(_ id: Int64, people: [Mention], hidden: Bool, lookup: (Int64) -> PersonRef?) -> String {
        let kept = people.first { $0.id == id }
        let ref = lookup(id)
        if !hidden, let name = kept?.name ?? ref?.name, !name.isEmpty { return name }
        let isGroup = kept?.isGroup ?? (ref?.kind == .group)
        return isGroup ? String(localized: "Group \(id)") : String(localized: "Person \(id)")
    }

    /// The text with every tag as a name. For a web page (`html`) names are
    /// escaped for where they land: HTML in the page, a string inside
    /// `<script>` or `<style>`. With names hidden, names typed out are
    /// hidden too (`hideTyped` turns them into tags first), in the page's
    /// text only, never in its markup or code.
    static func swap(
        _ text: String, people: [Mention], hidden: Bool, html: Bool,
        lookup: (Int64) -> PersonRef?, hideTyped: (String) -> String = { $0 }
    ) -> String {
        func label(_ id: Int64) -> String { Self.label(id, people: people, hidden: hidden, lookup: lookup) }
        func names(_ piece: Substring, escape: (String) -> String) -> String {
            String(piece.replacing(tagPattern) { match in
                guard let id = (match.1 ?? match.2).flatMap({ Int64($0) }) else { return String(match.0) }
                return escape(label(id))
            })
        }

        guard html else {
            let source = hidden ? hideTyped(text) : text
            let plain = MediaTag.replace(in: source) { media in
                guard let media else { return "" }
                return "“" + media.title + "”" + (media.by.map { " — " + $0 } ?? "")
            }
            return names(plain[...]) { $0 }
        }

        func page(_ piece: Substring) -> String {
            var piece = String(piece)
            if hidden {
                // Typed names in the text between tags, not inside them.
                var hiddenPiece = ""
                var at = piece.startIndex
                for markup in piece.matches(of: /<[^>]*>/) {
                    hiddenPiece += hideTyped(String(piece[at..<markup.range.lowerBound]))
                    hiddenPiece += piece[markup.range]
                    at = markup.range.upperBound
                }
                piece = hiddenPiece + hideTyped(String(piece[at...]))
            }
            piece = MediaTag.replace(in: piece) { media in
                guard let media else { return "" }
                return escapeHTML("“" + media.title + "”" + (media.by.map { " — " + $0 } ?? ""))
            }
            return names(piece[...], escape: escapeHTML)
        }

        // Scripts and styles are code: names there go in as string content.
        var result = ""
        var cursor = text.startIndex
        let code = /<(script|style)\b[^>]*>.*?<\/(?:script|style)\s*>/.ignoresCase().dotMatchesNewlines()
        for block in text.matches(of: code) {
            result += page(text[cursor..<block.range.lowerBound])
            result += names(text[block.range], escape: escapeScript)
            cursor = block.range.upperBound
        }
        return result + page(text[cursor...])
    }

    /// For Markdown shown in the app, where the directory's tags become
    /// links: only tags the directory does not know are written as names,
    /// from the artifact's own list. With names hidden nothing changes.
    static func fillUnknown(_ text: String, people: [Mention], hidden: Bool, lookup: (Int64) -> PersonRef?) -> String {
        guard !hidden, !people.isEmpty else { return text }
        return text.replacing(tagPattern) { match in
            guard let id = (match.1 ?? match.2).flatMap({ Int64($0) }), lookup(id) == nil,
                  let kept = people.first(where: { $0.id == id }) else { return String(match.0) }
            return escapeMarkdown(kept.name)
        }
    }

    // MARK: Escaping

    nonisolated static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Safe inside a JavaScript string of any quote, or a CSS string.
    nonisolated static func escapeScript(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "'": result += "\\'"
            case "`": result += "\\`"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "<": result += "\\x3C"
            case "\u{2028}": result += "\\u2028"
            case "\u{2029}": result += "\\u2029"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        for character in text {
            if "[]*_`\\<".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

extension Card.Artifact {
    /// The artifact as it shows in Agott: names, or "Person 12" while they
    /// are hidden. A web page is escaped for the page.
    func shownText(hidden: Bool) -> String {
        ArtifactNames.swap(content, people: people ?? [], hidden: hidden, html: kind == .html,
                           lookup: { PeopleDirectory.shared.name($0) },
                           hideTyped: { PeopleDirectory.shared.tagPlainNames($0) })
    }

    /// A web page as the panel shows it: names in place, Agott's sheet in front.
    func shownPage(hidden: Bool) -> String {
        ArtifactStyle.page(shownText(hidden: hidden), title: title)
    }

    /// Markdown for the in-app reader: tags the directory knows stay tags
    /// (they become names you can open); the rest are written from the
    /// artifact's own list.
    func shownMarkdown(hidden: Bool) -> String {
        ArtifactNames.fillUnknown(content, people: people ?? [], hidden: hidden,
                                  lookup: { PeopleDirectory.shared.name($0) })
    }

    /// The artifact as it leaves Agott (copied, saved, published): people's
    /// real names in place of their tags, as before; a web page also gets
    /// Agott's sheet, so it looks the same outside the app.
    var exportText: String {
        let text = ArtifactNames.swap(content, people: people ?? [], hidden: false, html: kind == .html,
                                      lookup: { PeopleDirectory.shared.name($0) })
        return kind == .html ? ArtifactStyle.page(text, title: title) : text
    }
}
