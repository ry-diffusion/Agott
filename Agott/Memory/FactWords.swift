import Foundation
import Translation

/// Facts in the reader's language. Learning used to write each fact's verb
/// in English ("plays", "works on"); it now writes it in the user's
/// language, and this rewrites the ones already learned, once: the common
/// verbs from a table (a translator gets "plays" or "has" wrong without the
/// rest of the sentence), the rest with the system's on-device Translation.
///
/// Everything up to the first run is English; that line is kept, so a run
/// cut short (Portuguese not downloaded for Translation yet) picks up the
/// rest later without touching what learning wrote since.
nonisolated enum FactWords {
    static let markKey = "factWords.englishThrough"
    static let doneKey = "factWords.done"

    static func migrate(store: MemoryStore = .shared) async {
        guard Persona.prefersPortuguese, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        do {
            let mark: MemoryStore.PredicateMark
            if let saved = UserDefaults.standard.dictionary(forKey: markKey),
               let facts = saved["facts"] as? Int64, let edges = saved["edges"] as? Int64 {
                mark = .init(facts: facts, edges: edges)
            } else {
                mark = try await store.predicateMark()
                UserDefaults.standard.set(["facts": mark.facts, "edges": mark.edges], forKey: markKey)
            }
            let english = try await store.predicates(through: mark)
            var map: [String: String] = [:]
            var rest: [String] = []
            let translatedAlready = Set(portuguese.values)
            for predicate in english where !translatedAlready.contains(predicate) {
                if let known = portuguese[predicate.lowercased()] { map[predicate] = known } else { rest.append(predicate) }
            }
            var complete = true
            if !rest.isEmpty {
                if let found = await translate(rest) {
                    map.merge(found) { first, _ in first }
                } else {
                    complete = false
                }
            }
            try await store.renamePredicates(map, through: mark)
            if complete { UserDefaults.standard.set(true, forKey: doneKey) }
        } catch {
            // The next launch tries again.
        }
    }

    /// English verb phrases to Portuguese on the Mac. Nil when the languages
    /// are not downloaded.
    static func translate(_ phrases: [String]) async -> [String: String]? {
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                         target: Locale.Language(identifier: "pt-BR"))
        var result: [String: String] = [:]
        do {
            for start in stride(from: 0, to: phrases.count, by: 100) {
                let batch = phrases[start..<min(start + 100, phrases.count)]
                // Alone, "plays" comes back as "brincadeiras"; after "she" it
                // is a verb ("ela brinca"), and "ela " comes off again. Words
                // that are not verbs ("birthday") keep the plain translation.
                var requests: [TranslationSession.Request] = []
                for phrase in batch {
                    requests.append(.init(sourceText: "she \(phrase)", clientIdentifier: "s|\(phrase)"))
                    requests.append(.init(sourceText: phrase, clientIdentifier: "b|\(phrase)"))
                }
                var withSubject: [String: String] = [:]
                var bare: [String: String] = [:]
                for response in try await session.translations(from: requests) {
                    guard let id = response.clientIdentifier else { continue }
                    let key = String(id.dropFirst(2))
                    let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                        .lowercased()
                    if id.hasPrefix("s|") { withSubject[key] = text } else { bare[key] = text }
                }
                for phrase in batch {
                    if let text = withSubject[phrase], text.hasPrefix("ela "), text.count > 4 {
                        result[phrase] = String(text.dropFirst(4))
                    } else if let text = bare[phrase], !text.isEmpty {
                        result[phrase] = text
                    }
                }
            }
            return result
        } catch {
            return nil
        }
    }

    /// The verbs facts use most, by hand: a translator gets "plays" or "has"
    /// wrong without the rest of the sentence.
    static let portuguese: [String: String] = [
        "works on": "trabalha em", "uses": "usa", "has": "tem", "likes": "gosta de", "wants": "quer",
        "owns": "tem", "plans": "planeja", "prefers": "prefere", "dislikes": "não gosta de", "is": "é",
        "wants to": "quer", "says": "diz", "plans to": "planeja", "plays": "joga", "thinks": "acha",
        "wants to buy": "quer comprar", "bought": "comprou", "is building": "está construindo", "is in": "está em",
        "plans to buy": "planeja comprar", "plans to build": "planeja construir", "studies at": "estuda em",
        "lives in": "mora em", "had": "teve", "wants to build": "quer construir", "built": "construiu",
        "made": "fez", "studies": "estuda", "plans to use": "planeja usar", "needs": "precisa de",
        "recommends": "recomenda", "is learning": "está aprendendo", "goes to": "vai a", "knows": "conhece",
        "feels": "se sente", "created": "criou", "works with": "trabalha com", "runs": "toca",
        "is interested in": "se interessa por", "organizes": "organiza", "knows about": "sabe de",
        "works at": "trabalha em", "reports": "conta", "manages": "cuida de", "is studying": "está estudando",
        "does": "faz", "considers": "considera", "builds": "constrói", "attends": "frequenta", "was": "foi",
        "proposes": "propõe", "plans to go to": "planeja ir a", "plans to add": "planeja adicionar",
        "participates in": "participa de", "is doing": "está fazendo", "does not have": "não tem",
        "was in": "esteve em", "suggests": "sugere", "says about self": "diz sobre si", "loves": "ama",
        "lost": "perdeu", "is considering buying": "está pensando em comprar", "is considering": "está pensando em",
        "fears": "tem medo de", "went to": "foi a", "watches": "assiste", "wants to be": "quer ser",
        "supports": "apoia", "self-describes as": "se descreve como", "plans to make": "planeja fazer",
        "lives": "mora", "is reading": "está lendo", "is making": "está fazendo", "describes self as": "se descreve como",
        "studies in": "estuda em", "set up": "configurou", "received": "recebeu", "plans to integrate": "planeja integrar",
        "plans to create": "planeja criar", "makes": "faz", "keeps": "guarda", "is selling": "está vendendo",
        "is responsible for": "é responsável por", "is migrating": "está migrando", "is good at": "é bom em",
        "is from": "é de", "is finishing": "está terminando", "is a fan of": "é fã de", "implemented": "implementou",
        "hates": "odeia", "has never": "nunca", "handles": "cuida de", "draws": "desenha",
        "describes himself as": "se descreve como", "describes herself as": "se descreve como", "decided": "decidiu",
        "asked to buy": "pediu para comprar", "writes": "escreve", "works as": "trabalha como",
        "wants to use": "quer usar", "used": "usou", "took": "pegou", "takes": "toma", "sold": "vendeu",
        "says he is": "diz que é", "says she is": "diz que é", "proposed": "propôs", "plans to migrate": "planeja migrar",
        "plans to implement": "planeja implementar", "participated in": "participou de",
        "birthday": "faz aniversário em", "does not drink": "não bebe", "uses hair cream": "usa creme de cabelo",
        "listens to": "ouve", "is dating": "namora", "dates": "namora", "is friends with": "é amigo de",
        "eats": "come", "drinks": "bebe", "does not like": "não gosta de", "wants to go to": "quer ir a",
        "is afraid of": "tem medo de", "is allergic to": "tem alergia a", "favorite": "favorito",
        "has a pet": "tem um pet", "follows": "segue", "reads": "lê", "is moving to": "está se mudando para",
        "moved to": "mudou para", "was born in": "nasceu em", "is from city": "é de", "speaks": "fala",
        "is learning to": "está aprendendo a", "wants to learn": "quer aprender", "travels to": "viaja para",
        "traveled to": "viajou para", "graduated from": "se formou em", "age": "idade", "is aged": "tem",
        "nickname": "apelido", "works in": "trabalha em", "studied at": "estudou em", "sings": "canta",
    ]
}

extension MemoryStore.LinkKind {
    /// The link as a sentence fragment in the reader's language: "namora", "estuda com".
    func phrase(outgoing: Bool) -> String {
        switch self {
        case .partner: String(localized: "is dating")
        case .ex: String(localized: "is the ex of")
        case .crush: outgoing ? String(localized: "has a crush on") : String(localized: "is the crush of")
        case .family: String(localized: "is family of")
        case .sibling: String(localized: "is a sibling of")
        case .parent: outgoing ? String(localized: "is a parent of") : String(localized: "is a child of")
        case .friend: String(localized: "is friends with")
        case .bestFriend: String(localized: "is best friends with")
        case .classmate: String(localized: "studies with")
        case .coworker: String(localized: "works with")
        case .roommate: String(localized: "lives with")
        case .conflict: String(localized: "has a conflict with")
        }
    }
}
