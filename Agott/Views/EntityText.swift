import SwiftUI

/// Tags for people and groups (`<e id=12/>`) as the chat shows them: the
/// name in Agott's purple, a link to the person, or "Person 12" while names
/// are hidden.
enum EntityText {
    /// Tags as Markdown links, ready for the inline Markdown parser. A tag
    /// still being written at the end of a streaming reply is held back.
    static func markdown(_ text: String, hidden: Bool) -> String {
        var source = hidden ? PeopleDirectory.shared.tagPlainNames(text) : text
        if let start = source.range(of: "<e", options: .backwards),
           !source[start.lowerBound...].contains(">"),
           source.distance(from: start.lowerBound, to: source.endIndex) < 16 {
            source = String(source[..<start.lowerBound])
        }
        return source.replacing(/<e id="?(\d+)"?\s*\/?>/) { match in
            let id = Int64(match.1) ?? 0
            let label = escape(PeopleDirectory.shared.label(id, hidden: hidden))
            return "[\(label)](agott://person/\(id))"
        }
    }

    /// Tags as plain words, for one-line previews, titles and copying.
    static func plain(_ text: String, hidden: Bool) -> String {
        let source = hidden ? PeopleDirectory.shared.tagPlainNames(text) : text
        return source.replacing(/<e id="?(\d+)"?\s*\/?>/) { match in
            PeopleDirectory.shared.label(Int64(match.1) ?? 0, hidden: hidden)
        }
    }

    /// People links drawn as names: purple and bold, no underline.
    static func style(_ text: inout AttributedString) {
        for run in text.runs where run.link?.scheme == "agott" {
            text[run.range].foregroundColor = Ink.spot
            text[run.range].inlinePresentationIntent = .stronglyEmphasized
            text[run.range].underlineStyle = nil
        }
    }

    private static func escape(_ label: String) -> String {
        var result = ""
        for character in label {
            if "[]*_`\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Opens a person from a link in the chat: their page in People.
    static func open(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "agott", url.host() == "person",
              let id = Int64(url.lastPathComponent), let ref = PeopleDirectory.shared.name(id) else { return .systemAction }
        let store = PeopleStore.shared
        Navigator.shared.section = .people
        if let row = store.rows.first(where: { $0.chat.name.folded == ref.name.folded }) {
            store.search = ""
            store.selection = row.id
        } else {
            store.search = ref.name
        }
        return .handled
    }
}

extension EntityText {
    /// Text written for the model, made readable for a person: the note
    /// that tells the model how to write tags is dropped, and every tag is
    /// the person's name (or "Person 12" with names hidden). Only the final
    /// answer keeps tags, which become chips there.
    static func readable(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").filter { line in
            !line.hasPrefix("People and groups, by tag.") && !line.hasPrefix("group is never a person")
        }
        return plain(lines.joined(separator: "\n"), hidden: AppSettings.shared.hideNames)
    }
}

extension Card.Artifact {
    /// The artifact as it leaves Agott (copied, saved, published): people's
    /// tags turned into their names.
    var exportText: String { EntityText.plain(content, hidden: false) }
}
