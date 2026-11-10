//
//  ArtifactNamesTests.swift
//  AgottTests
//

import Foundation
import Testing
@testable import Agott

@MainActor
struct ArtifactNamesTests {
    private let directory: [Int64: PersonRef] = [
        12: PersonRef(id: 12, kind: .person, name: "Ana Souza"),
        40: PersonRef(id: 40, kind: .group, name: "Família"),
    ]
    private func lookup(_ id: Int64) -> PersonRef? { directory[id] }

    @Test func mentionsAreKeptOnceEach() {
        let mentions = ArtifactNames.mentions(in: "<e id=12/> and <e id=\"40\"/> and <e id=12/> and <e id=99/>", lookup: lookup)
        #expect(mentions == [.init(id: 12, name: "Ana Souza"), .init(id: 40, name: "Família", isGroup: true)])
    }

    @Test func documentTagsBecomeNames() {
        let text = "# Plan with <e id=12/>\n\nAsk <e id=40/> and <e id=7/>."
        let shown = ArtifactNames.swap(text, people: [.init(id: 7, name: "Bia")], hidden: false, html: false, lookup: lookup)
        #expect(shown == "# Plan with Ana Souza\n\nAsk Família and Bia.")
    }

    @Test func keptNamesWinAndSurviveWithoutTheDirectory() {
        let kept: [Card.Artifact.Mention] = [.init(id: 12, name: "Ana S.")]
        #expect(ArtifactNames.swap("Hi <e id=12/>", people: kept, hidden: false, html: false, lookup: lookup) == "Hi Ana S.")
        #expect(ArtifactNames.swap("Hi <e id=12/>", people: kept, hidden: false, html: false, lookup: { _ in nil }) == "Hi Ana S.")
        #expect(ArtifactNames.swap("Hi <e id=5/>", people: [], hidden: false, html: false, lookup: { _ in nil })
                == "Hi " + String(localized: "Person \(Int64(5))"))
    }

    @Test func hiddenNamesStayHidden() {
        let shown = ArtifactNames.swap("<e id=12/> in <e id=40/>", people: [.init(id: 12, name: "Ana Souza")],
                                       hidden: true, html: false, lookup: lookup)
        #expect(shown == String(localized: "Person \(Int64(12))") + " in " + String(localized: "Group \(Int64(40))"))
    }

    @Test func hiddenAlsoHidesTypedNamesOnlyInPageText() {
        let html = "<p class=\"Ana\">Ana wrote</p>"
        let shown = ArtifactNames.swap(html, people: [], hidden: true, html: true, lookup: lookup,
                                       hideTyped: { $0.replacingOccurrences(of: "Ana", with: "<e id=12/>") })
        #expect(shown == "<p class=\"Ana\">" + String(localized: "Person \(Int64(12))") + " wrote</p>")
    }

    @Test func pageNamesAreEscapedForWhereTheyLand() {
        let people: [Card.Artifact.Mention] = [.init(id: 3, name: "Zé \"<Boss>\" & Co")]
        let html = """
        <h1><e id=3/></h1><div title="<e id=3/>"></div>
        <script>const who = "<e id=3/>";</script>
        <p>&lt;e id=3/&gt;</p>
        """
        let shown = ArtifactNames.swap(html, people: people, hidden: false, html: true, lookup: lookup)
        #expect(shown.contains("<h1>Zé &quot;&lt;Boss&gt;&quot; &amp; Co</h1>"))
        #expect(shown.contains("title=\"Zé &quot;&lt;Boss&gt;&quot; &amp; Co\""))
        #expect(shown.contains("const who = \"Zé \\\"\\x3CBoss>\\\" & Co\";"))
        #expect(shown.contains("<p>Zé &quot;&lt;Boss&gt;&quot; &amp; Co</p>"))
        #expect(!shown.contains("<e id"))
    }

    @Test func markdownKeepsTagsTheDirectoryKnows() {
        let people: [Card.Artifact.Mention] = [.init(id: 12, name: "Ana Souza"), .init(id: 8, name: "Caio_*")]
        let text = "<e id=12/> met <e id=8/>"
        #expect(ArtifactNames.fillUnknown(text, people: people, hidden: false, lookup: lookup) == "<e id=12/> met Caio\\_\\*")
        #expect(ArtifactNames.fillUnknown(text, people: people, hidden: true, lookup: lookup) == text)
    }

    @Test func olderArtifactsDecodeWithoutPeople() throws {
        let artifact = Card.Artifact(key: "plan", title: "Plan", kind: .document, content: "Hi <e id=1/>")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(artifact)) as? [String: Any] ?? [:]
        json.removeValue(forKey: "people")
        let decoded = try JSONDecoder().decode(Card.Artifact.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.people == nil)
        #expect(decoded.content == artifact.content)
    }

    @Test func sheetGoesInFrontOfThePagesOwnStyles() {
        let full = "<!doctype html><html><head><style>body{color:red}</style></head><body>x</body></html>"
        let styled = ArtifactStyle.page(full, title: "T")
        let sheet = styled.range(of: "id=\"agott-style\"")?.lowerBound
        let own = styled.range(of: "body{color:red}")?.lowerBound
        #expect(sheet != nil && own != nil && sheet! < own!)

        let fragment = ArtifactStyle.page("<h1>Hi</h1>", title: "A & B")
        #expect(fragment.hasPrefix("<!doctype html>"))
        #expect(fragment.contains("<title>A &amp; B</title>"))
        #expect(fragment.contains("<body>\n<h1>Hi</h1>\n</body>"))
        #expect(ArtifactStyle.css.contains("--bg: #fcfcfb;"))
        #expect(ArtifactStyle.css.contains("--bg: #262626;"))
    }
}
