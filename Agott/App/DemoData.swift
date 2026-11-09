import Foundation

/// Launch options for design review and screenshots.
///
/// `-AgottDemo` runs Agott on a throwaway database of made-up people, so every
/// screen can be shown full without a single real message in it. Nothing is
/// indexed from this Mac in demo mode.
enum LaunchOptions {
    nonisolated static let arguments = ProcessInfo.processInfo.arguments

    nonisolated static var isDemo: Bool { arguments.contains("-AgottDemo") }

    nonisolated static func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static var section: AppSection? { value("-AgottSection").flatMap(AppSection.init(rawValue:)) }
    static var showOnboarding: Bool { arguments.contains("-AgottShowOnboarding") }
    static var showOverlay: Bool { arguments.contains("-AgottOverlay") }
    static var selectFirst: Bool { arguments.contains("-AgottSelectFirst") }
    /// Demo only: read the selected person's story as soon as it opens.
    static var runRead: Bool { isDemo && arguments.contains("-AgottRunRead") }
}

enum DemoData {
    /// One throwaway database per demo run; older runs' files are cleared
    /// the first time it is asked for.
    nonisolated static let databaseURL: URL = {
        let folder = URL.cachesDirectory.appending(path: "AgottDemo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = "demo-\(ProcessInfo.processInfo.processIdentifier)"
        let hourAgo = Date().addingTimeInterval(-3600)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where !file.lastPathComponent.hasPrefix(mine) {
            // Leave runs from the last hour alone: they may still be open.
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < hourAgo { try? FileManager.default.removeItem(at: file) }
        }
        return folder.appending(path: "\(mine).sqlite")
    }()

    static func seed() async {
        let me = AppSettings.myNameSnapshot
        let now = Date()
        var messages: [RawMessage] = []
        var counter = 0

        func add(_ chat: String, group: Bool = false, _ lines: [(String, Double, String)]) {
            for (sender, hoursAgo, text) in lines {
                counter += 1
                let isMe = sender == "me"
                messages.append(RawMessage(
                    source: chat.hasPrefix("i:") ? .imessage : .whatsapp,
                    externalID: "demo-\(counter)", chatID: chat, chatName: String(chat.drop(while: { $0 != ":" }).dropFirst()),
                    isGroup: group, sender: isMe ? me : sender, isFromMe: isMe,
                    date: now.addingTimeInterval(-hoursAgo * 3600), text: text))
            }
        }

        // Weeks of history so the charts have shape.
        for week in stride(from: 11, through: 1, by: -1) {
            let base = Double(week) * 168
            add("w:Ana Souza", [
                ("Ana Souza", base + 30, "Bom diaaa ☀️"), ("me", base + 29.5, "bom dia!! dormiu bem?"),
                ("Ana Souza", base + 29, "Mais ou menos kkk, e você?"), ("me", base + 28, "tranquilo, bora café mais tarde?"),
            ])
            add("w:Lia (trabalho)", [
                ("Lia (trabalho)", base + 50, "Conseguiu ver o PR do onboarding?"), ("me", base + 47, "vi sim, deixei uns comentários"),
            ])
        }
        add("w:Ana Souza", [
            ("Ana Souza", 30, "E aí, bora pra Floripa no feriado? 🏖️"),
            ("me", 29.5, "boraaa, vou ver as passagens hoje"),
            ("Ana Souza", 29, "Já falei com a Mariana, ela topa"),
            ("Ana Souza", 6, "Achei uma pousada perto da Lagoa, tô de boa na lagoa kkkk"),
            ("Ana Souza", 5.8, "Fecha a passagem até sexta?"),
        ])
        add("w:Mãe", [
            ("Mãe", 200, "Filho, domingo tem almoço aqui"), ("me", 199, "vou sim mãe ❤️"),
            ("Mãe", 52, "Não esquece o remédio do seu pai"), ("me", 51, "pode deixar, compro amanhã"),
        ])
        add("w:Faculdade 2026", group: true, [
            ("João Pedro", 80, "Galera, a entrega de SI é quinta"), ("Mariana", 79, "Alguém já começou?"),
            ("me", 78, "eu faço a parte do banco"), ("me", 77, "e a ana de novo não respondeu, sempre some na hora de entregar"),
            ("Mariana", 76, "kkkk a Ana é assim mesmo"), ("João Pedro", 20, "Bora call hoje 21h?"),
            ("Mariana", 19.5, "Fechou"),
        ])
        add("w:Família Sousa", group: true, [
            ("Mãe", 120, "Quem vem no domingo?"), ("Pai", 119, "Eu levo o carvão"), ("Tia Rosa", 118, "Levo a sobremesa 🍰"),
            ("Mãe", 60, "Não esqueçam o aniversário da vó"), ("Pai", 59, "Já comprei o presente"), ("Tia Rosa", 58, "Que lindo!"),
            ("me", 57, "chego meio dia"),
        ])
        add("w:Pelada de quinta", group: true, [
            ("João Pedro", 90, "Quadra confirmada 20h"), ("Lucas", 89, "Tô dentro"), ("Rafa", 88, "Eu levo a bola"),
            ("João Pedro", 40, "Faltam 2 pra fechar"), ("Lucas", 39, "Chamo meu primo"), ("Rafa", 38, "Bora"),
            ("me", 37, "tô dentro também"),
        ])
        add("i:João Pedro", [
            ("João Pedro", 400, "Viu o jogo do Palmeiras?"), ("me", 399, "vi, que sofrimento"),
            ("João Pedro", 3, "Tá vivo? 😂"),
        ])

        let store = MemoryStore.shared
        _ = try? await store.ingest(messages)
        _ = try? await KnowledgeGraph.link(store: store)
        let facts: [(String, String, String, Double)] = [
            (me, "works on", "Agott", 0.95), (me, "uses", "SwiftUI", 0.9), (me, "is learning", "Foundation Models", 0.8),
            (me, "likes", "Palmeiras", 0.85), (me, "lives in", "Brasil", 0.9), ("Ana Souza", "is planning", "trip to Floripa", 0.8),
            (me, "studies", "Sistemas de Informação", 0.75), ("Mãe", "hosts", "Sunday lunch", 0.7),
        ]
        for (s, p, o, c) in facts {
            try? await store.addFact(subject: s, predicate: p, object: o, confidence: c, source: .claude, chunkID: nil, at: now)
            await KnowledgeGraph.link(subject: s, predicate: p, object: o, kind: p == "lives in" ? .place : .topic, at: now)
        }
        let circles = [
            PeopleCircle(id: "circle-0", name: String(localized: "Family"), kind: .family,
                         why: String(localized: "Sunday lunches and grandma's birthday."),
                         members: ["Mãe", "Pai", "Tia Rosa"], groups: ["Família Sousa"]),
            PeopleCircle(id: "circle-1", name: String(localized: "College"), kind: .school,
                         why: String(localized: "The Information Systems class group."),
                         members: ["João Pedro", "Mariana"], groups: ["Faculdade 2026"]),
            PeopleCircle(id: "circle-2", name: String(localized: "Thursday football"), kind: .hobby,
                         why: String(localized: "The weekly match crew."),
                         members: ["João Pedro", "Lucas", "Rafa"], groups: ["Pelada de quinta"]),
        ]
        if let data = try? JSONEncoder().encode(circles), let json = String(data: data, encoding: .utf8) {
            try? await store.saveInsight(json, key: Circles.insightKey)
        }
        let consistency = Card.Consistency(
            name: "Ana Souza", gap: 38,
            verdict: String(localized: "Mostly consistent, with one complaint about her that you never said to her."),
            toThem: String(localized: "Warm and quick to say yes, lots of plans together."),
            aboutThem: String(localized: "Once, in the college group, you complained she disappears near deadlines."),
            othersAboutThem: String(localized: "Mariana laughed it off; nothing harsh from anyone else."),
            quotes: [
                .init(text: "boraaa, vou ver as passagens hoje", context: String(localized: "to Ana"), direct: true),
                .init(text: "e a ana de novo não respondeu, sempre some na hora de entregar", context: String(localized: "about Ana in Faculdade 2026"), direct: false),
            ],
            advice: String(localized: "If the deadlines bother you, tell her directly next time. It'll land better than the group chat."),
            toneToThem: 0.6, toneAboutThem: -0.4, mentionCount: 1)
        if let data = try? JSONEncoder().encode(consistency), let json = String(data: data, encoding: .utf8) {
            try? await store.saveInsight(json, key: "consistency:whatsapp:w:Ana Souza")
        }
        await Indexer.shared.refreshTotals()
    }

    /// Made-up chats for the sidebar, the first being the open one.
    static func conversations(current: UUID) -> [ConversationInfo] {
        let now = Date()
        func info(_ id: UUID, _ subject: String, _ preview: String, _ people: [String], _ hoursAgo: Double) -> ConversationInfo {
            var item = ConversationInfo(id: id, title: subject, preview: preview, updated: now.addingTimeInterval(-hoursAgo * 3600))
            item.subject = subject
            item.people = people
            return item
        }
        return [
            info(current, "Ana e a viagem", "amanhã tá tranquilo, só a call da turma à noite", ["Ana Souza"], 0),
            info(UUID(), "Presente pra mãe", "que tal um livro de receitas da vó?", [], 2),
            info(UUID(), "Rolê de sexta", "o Lucas topou, falta a Rafa", ["Lucas", "Rafa", "João"], 26),
            info(UUID(), "Estudar pra prova", "montei um plano de três dias", [], 50),
            info(UUID(), "Como responder o Bruno", "manda curto e sincero", ["Bruno Reis"], 100),
        ]
    }

    static func turns() -> [Turn] {
        let explanation = Card.Explanation(
            term: "tô de boa na lagoa",
            meaning: String(localized: "A playful way to say you're relaxed and carefree. It rhymes, so it's used as a joke more than literally."),
            examples: [
                .init(text: "Prova amanhã? Tô de boa na lagoa 😎", note: String(localized: "Not worried at all")),
                .init(text: "Hoje é só série e pipoca, de boa na lagoa", note: String(localized: "A chill day with no plans")),
            ],
            tip: String(localized: "Ana is joking because the inn is literally near the Lagoa da Conceição."))
        let replies = Card.Replies(
            context: String(localized: "Ana wants you to book the tickets by Friday."),
            options: [
                .init(text: "fechado! compro amanhã cedo e te mando print 🏖️", tone: "animado", why: String(localized: "Commits to a time, like she asked")),
                .init(text: "boraa, só confirmo o valor e já fecho", tone: "direto", why: String(localized: "Honest about checking the price first")),
                .init(text: "de boa na lagoa 😂 sexta tá na mão", tone: "brincalhão", why: String(localized: "Plays with her joke")),
            ])
        let person = Card.PersonRead(
            name: "Ana Souza", closeness: 86, vibe: String(localized: "warm and playful"),
            summary: String(localized: "Ana is one of your closest friends. You talk most mornings, she usually starts the conversation, and lately it's all about the Floripa trip."),
            openLoops: [String(localized: "Book the tickets by Friday")],
            suggestions: [String(localized: "Send her the ticket options today; she's been waiting since this morning.")])
        let events = Card.EventList(title: String(localized: "Calendar"), items: [
            .init(title: "Call do grupo de SI", start: Date().addingTimeInterval(3600 * 9), end: nil, detail: "Google Meet"),
            .init(title: "Almoço de domingo", start: Date().addingTimeInterval(3600 * 50), end: nil, detail: "Casa da mãe"),
        ])
        let approval = Card.Approval(
            title: String(localized: "Run a script"),
            detail: "Play a chill playlist in Music\n\ntell application \"Music\" to play playlist \"Chill\"")
        return [
            Turn(role: .user, text: "o que significa “tô de boa na lagoa”?", screenApp: "WhatsApp", memoryCount: 3),
            Turn(role: .assistant, text: String(localized: "haha it's slang, relax\n\nshe's not actually at the lagoon. well, almost"), cards: [.explanation(explanation)],
                 steps: [
                    Step(id: "d1", kind: .context, title: String(localized: "Looked at WhatsApp"), symbol: "eye", state: .done,
                         started: Date().addingTimeInterval(-9), ended: Date().addingTimeInterval(-8)),
                    Step(id: "d2", kind: .context, title: String(localized: "Remembered 3 things"), symbol: "brain.head.profile", state: .done,
                         detail: "· Ana Souza\n· Faculdade 2026", started: Date().addingTimeInterval(-8), ended: Date().addingTimeInterval(-8)),
                    Step(id: "d3", kind: .thinking, title: String(localized: "Thinking"), symbol: "brain", state: .done,
                         detail: String(localized: "She's joking about the inn near the lagoon; explain the slang with two examples."),
                         started: Date().addingTimeInterval(-8), ended: Date().addingTimeInterval(-5)),
                    Step(id: "d4", kind: .tool, title: String(localized: "Writing an explanation"), symbol: "lightbulb", state: .done,
                         started: Date().addingTimeInterval(-5), ended: Date().addingTimeInterval(-4)),
                 ]),
            Turn(role: .user, text: "e como eu respondo ela?", memoryCount: 5),
            Turn(role: .assistant, text: String(localized: "she's been waiting since this morning\n\nhere, in your style:"), cards: [.replies(replies)]),
            Turn(role: .user, text: "como tá minha relação com a Ana?"),
            Turn(role: .assistant, text: "", cards: [.person(person)]),
            Turn(role: .user, text: "o que tenho amanhã? e toca algo tranquilo"),
            Turn(role: .assistant, text: String(localized: "tomorrow's light, just the class call at night\n\nputting something chill on. just confirm:"), cards: [.events(events), .approval(approval)]),
            Turn(role: .user, text: "qual música eu mais ouvi esse mês?"),
            Turn(role: .assistant, text: """
                então meu chute é <media kind="song" title="Do I Wanna Know?" by="Arctic Monkeys"/> — aquele riff é literalmente uma linha de baixo do tamanho de um prédio.

                | # | Música | Artista | Plays |
                |---|---|---|---|
                | 1 | Do I Wanna Know? | Arctic Monkeys | 42 |
                | 2 | Desleixado | KARNIVAL | 31 |
                | 3 | Pink + White | Frank Ocean | 18 |
                """, cards: [.collection(.init(
                    title: "Seu top do mês", subtitle: "Spotify · Últimas 4 semanas", style: .ranking, kind: "song",
                    items: [.init(title: "Do I Wanna Know?", subtitle: "Arctic Monkeys", detail: "42 plays"),
                            .init(title: "Desleixado", subtitle: "KARNIVAL", detail: "31 plays"),
                            .init(title: "Pink + White", subtitle: "Frank Ocean", detail: "18 plays")]))]),
        ]
    }
}
