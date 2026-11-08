import Foundation

/// How someone has been feeling lately in their chat with you, judged by Jev
/// from the conversation itself.
///
/// The system's sentiment tagger reads words one paragraph at a time, so
/// "porra que saudade, sua idiota kkkk" comes out negative. Jev reads both
/// sides of the latest messages together and judges swearing, teasing and
/// insults the way friends mean them. The tagger stays as the fallback when
/// TypeSafe is not set up or does not answer.
nonisolated enum ChatMood {
    static let levels = [
        "Upset, hurt, angry or in a bad place, and it shows in how they write to the user.",
        "Down, tired, distant or a bit off.",
        "Fine and ordinary: practical talk, nothing much either way.",
        "In a good mood: warm, relaxed, joking around.",
        "Very happy or affectionate: excited, loving, having a great time with the user.",
    ]

    /// -1 (bad) to 1 (great), like the tagger's scale. Nil when Jev cannot say.
    static func judge(_ chat: ChatSummary, store: MemoryStore = .shared) async -> Double? {
        let stamp = "\(chat.messageCount)|\(chat.lastDate.timeIntervalSince1970)"
        let key = "mood.\(chat.id)"
        if let cached = UserDefaults.standard.dictionary(forKey: key),
           cached["stamp"] as? String == stamp, let value = cached["value"] as? Double {
            return value
        }
        guard Jev.isConfigured else { return nil }
        let lines = ((try? await store.lines(source: chat.source, chatID: chat.chatID, limit: 8000)) ?? []).suffix(60)
        guard lines.contains(where: { !$0.isFromMe }) else { return nil }
        let me = AppSettings.myNameSnapshot
        let conversation = lines.map { line in
            "\(line.isFromMe ? me : chat.name): \(line.text.prefix(240))"
        }
        let state: [String: Any] = [
            "user": "\(me) (the user)",
            "person": chat.name,
            "conversation": conversation,
        ]
        let question = Jev.Question.score("""
        Reading `conversation` as a whole, how is `person` feeling lately in their chat with the user? \
        Judge swearing, insults, teasing, "kkkk" and dark jokes by context: between friends in Brazilian \
        Portuguese they are usually banter and affection, not anger. Only count it as bad when they are \
        really upset, hurt or distant.
        """, levels)
        guard let answers = try? await Jev.ask(state: state, questions: ["mood": question]),
              let score = answers["mood"]?.score else { return nil }
        let value = max(-1, min(1, (score - 2) / 2))
        UserDefaults.standard.set(["stamp": stamp, "value": value], forKey: key)
        return value
    }
}
