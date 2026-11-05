import Foundation
import FoundationModels

/// The circles of your life, found rather than filed.
///
/// Nobody tags their contacts "family" or "college". But the groups you are
/// in say it for you: the people who keep turning up in the same group chats
/// belong together. Agott builds a graph where two people are linked by every
/// group they share (weighted by how much both of them actually talk there),
/// lets communities settle out of it with label propagation, and then asks the
/// model to name each one from the group chats it came from.
nonisolated struct PeopleCircle: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var kind: Kind
    var why: String
    var members: [String]
    var groups: [String]

    enum Kind: String, Codable, Sendable, CaseIterable {
        case family, work, school, friends, community, hobby, other

        var symbol: String {
            switch self {
            case .family: "house"
            case .work: "briefcase"
            case .school: "graduationcap"
            case .friends: "person.2"
            case .community: "building.columns"
            case .hobby: "figure.run"
            case .other: "circle.dashed"
            }
        }
    }
}

enum Circles {
    static let insightKey = "circles"

    // MARK: Detection

    @concurrent nonisolated static func detect(store: MemoryStore = .shared, since: Date = Date().addingTimeInterval(-365 * 86400))
        async throws -> [Draft]
    {
        let membership = try await store.groupMembership(since: since)
        // Very large groups (announcements, communities) say little about closeness.
        var chatSizes: [String: Int] = [:]
        for row in membership { chatSizes[row.chat, default: 0] += 1 }
        let useful = membership.filter { (chatSizes[$0.chat] ?? 0) >= 2 && (chatSizes[$0.chat] ?? 0) <= 60 }

        var byChat: [String: [(String, Int)]] = [:]
        var chatNames: [String: String] = [:]
        for row in useful {
            byChat[row.chat, default: []].append((row.person, row.count))
            chatNames[row.chat] = row.chatName
        }

        // Person–person weights.
        var weights: [String: [String: Double]] = [:]
        var groupsOf: [String: [String: Int]] = [:]
        for (chat, people) in byChat {
            let size = Double(people.count)
            for (person, count) in people { groupsOf[person, default: [:]][chat] = count }
            for i in people.indices {
                for j in people.indices where j > i {
                    let w = log1p(Double(min(people[i].1, people[j].1))) / sqrt(size)
                    weights[people[i].0, default: [:]][people[j].0, default: 0] += w
                    weights[people[j].0, default: [:]][people[i].0, default: 0] += w
                }
            }
        }

        // Weighted label propagation, deterministic order.
        let people = weights.keys.sorted()
        var label = Dictionary(uniqueKeysWithValues: people.map { ($0, $0) })
        for _ in 0..<25 {
            var changed = false
            for person in people {
                var score: [String: Double] = [:]
                for (other, w) in weights[person] ?? [:] { score[label[other] ?? other, default: 0] += w }
                guard let best = score.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key else { continue }
                if best != label[person] { label[person] = best; changed = true }
            }
            if !changed { break }
        }

        var clusters: [String: [String]] = [:]
        for (person, l) in label { clusters[l, default: []].append(person) }

        return clusters.values
            .filter { $0.count >= 2 }
            .map { members -> Draft in
                // The group chats this circle lives in, strongest first.
                var groupScore: [String: Int] = [:]
                for member in members {
                    for (chat, count) in groupsOf[member] ?? [:] { groupScore[chat, default: 0] += count }
                }
                let groups = groupScore.sorted { $0.value > $1.value }.prefix(4).compactMap { chatNames[$0.key] }
                let ranked = members.sorted {
                    (groupsOf[$0]?.values.reduce(0, +) ?? 0) > (groupsOf[$1]?.values.reduce(0, +) ?? 0)
                }
                return Draft(members: ranked, groups: Array(groups))
            }
            .sorted { $0.members.count > $1.members.count }
            .prefix(12)
            .map { $0 }
    }

    nonisolated struct Draft: Sendable {
        var members: [String]
        var groups: [String]
    }

    // MARK: Naming

    @Generable
    struct Naming {
        @Guide(description: "A short, warm name for this circle of people, two or three words, in the user's language")
        var name: String
        @Guide(description: "What kind of circle it is")
        var kind: Kind
        @Guide(description: "One short sentence on why these people belong together")
        var why: String

        @Generable
        enum Kind { case family, work, school, friends, community, hobby, other }
    }

    /// Detects circles and names them. Saves the result for the People screen.
    static func refresh() async throws -> [PeopleCircle] {
        let drafts = try await detect()
        var circles: [PeopleCircle] = []
        for (index, draft) in drafts.enumerated() {
            let fallback = draft.groups.first ?? String(localized: "Circle \(index + 1)")
            var circle = PeopleCircle(
                id: "circle-\(index)", name: fallback, kind: .other, why: "",
                members: draft.members, groups: draft.groups)
            if let naming = try? await ModelHub.generate(
                Naming.self,
                prompt: """
                Group chats these people share: \(draft.groups.joined(separator: "; "))
                People: \(draft.members.prefix(12).joined(separator: ", "))
                """,
                instructions: """
                You name the social circles in the user's life from the group chats they share. Use the group \
                names as the main clue (e.g. "Família Sousa" means family, "Faculdade SI 2026" means college). \
                Write in \(Persona.languageName).
                """,
                provider: ModelHub.bulkProvider)
            {
                circle.name = naming.name
                circle.why = naming.why
                circle.kind = PeopleCircle.Kind(rawValue: "\(naming.kind)") ?? .other
            }
            circles.append(circle)
        }
        if let data = try? JSONEncoder().encode(circles), let json = String(data: data, encoding: .utf8) {
            try? await MemoryStore.shared.saveInsight(json, key: insightKey)
        }
        return circles
    }

    static func cached() async -> [PeopleCircle] {
        guard let (json, _) = try? await MemoryStore.shared.insight(key: insightKey),
              let circles = try? JSONDecoder().decode([PeopleCircle].self, from: Data(json.utf8))
        else { return [] }
        return circles
    }
}

/// Lets the model answer "who are my work people?" and similar.
nonisolated struct CirclesTool: Tool {
    let name = "people_circles"
    let description = "List the user's social circles (family, work, college, friends…) that Agott detected from shared group chats, with their members."

    @Generable
    struct Arguments {
        @Guide(description: "Optional circle name or kind to focus on")
        var filter: String?
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Looking at your circles…"))
        var circles = await Circles.cached()
        if circles.isEmpty { circles = (try? await Circles.refresh()) ?? [] }
        if let filter = arguments.filter?.folded, !filter.isEmpty {
            circles = circles.filter { $0.name.folded.contains(filter) || $0.kind.rawValue.contains(filter) }
        }
        guard !circles.isEmpty else { return "No circles detected yet; the user may not be in shared group chats." }
        return circles.map { circle in
            "- \(circle.name) (\(circle.kind.rawValue)): \(circle.members.prefix(15).joined(separator: ", ")). From groups: \(circle.groups.joined(separator: "; ")). \(circle.why)"
        }.joined(separator: "\n")
    }
}
