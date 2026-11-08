import SwiftUI

/// Your conversations with Agott, the way a messenger lists chats: who it is
/// about, what it is about, and how it ended.
struct ConversationSidebar: View {
    @State private var agent = Agent.shared
    @State private var navigator = Navigator.shared
    @State private var query = ""

    /// A row is selected only while the chat itself is on screen.
    private var inChat: Bool { navigator.section == .chat }

    private var shown: [ConversationInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return agent.conversations }
        return agent.conversations.filter {
            $0.displayTitle.localizedStandardContains(q) || $0.preview.localizedStandardContains(q)
                || ($0.people ?? []).contains { $0.localizedStandardContains(q) }
        }
    }

    /// A conversation just started and not saved yet.
    private var isDraft: Bool { !agent.conversations.contains { $0.id == agent.currentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(iOS)
            HStack {
                Text("Chats").font(.headline).foregroundStyle(Ink.text)
                Spacer()
                Button {
                    withAnimation(Motion.settle) { agent.newConversation() }
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(HoverIconStyle(size: 30))
            }
            .padding(.horizontal, 6)
            #endif

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                TextField(String(localized: "Search"), text: $query).textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Ink.text.opacity(0.07)))

            ScrollView {
                LazyVStack(spacing: 2) {
                    if isDraft && query.isEmpty {
                        ConversationRow(
                            info: ConversationInfo(id: agent.currentID, title: String(localized: "New conversation"),
                                                   preview: "", updated: .now),
                            selected: inChat) { navigator.section = .chat }
                    }
                    ForEach(shown) { item in
                        ConversationRow(info: item, selected: inChat && item.id == agent.currentID) {
                            navigator.section = .chat
                            withAnimation(Motion.settle) { agent.open(item.id) }
                        }
                        .contextMenu {
                            Button("Delete conversation", systemImage: "trash", role: .destructive) {
                                withAnimation(Motion.settle) { agent.delete(item.id) }
                            }
                        }
                    }
                    if shown.isEmpty && !query.isEmpty {
                        Text("No conversations match").font(.callout).foregroundStyle(Ink.muted).padding(.top, 20)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
    }
}

private struct ConversationRow: View {
    var info: ConversationInfo
    var selected: Bool
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                PeopleAvatar(people: info.people ?? [], size: 46, onSpot: selected,
                             title: info.subject)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(EntityText.plain(info.displayTitle, hidden: AppSettings.shared.hideNames))
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.time(info.updated))
                            .font(.caption)
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(Ink.muted))
                    }
                    // A reply still being written here, even while you are
                    // in another chat: Telegram's "typing…".
                    if Agent.shared.isBusy && Agent.shared.runningConversation == info.id {
                        Text("typing…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.spot))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(Ink.muted))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Ink.spot) : AnyShapeStyle(Ink.text.opacity(hovering ? 0.06 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Who it is about, then how it ended.
    private var subtitle: String {
        let hidden = AppSettings.shared.hideNames
        let people = EntityText.plain((info.people ?? []).joined(separator: ", "), hidden: hidden)
        let preview = EntityText.plain(info.preview.markdownStripped, hidden: hidden)
        if people.isEmpty { return preview.isEmpty ? String(localized: "Say hi") : preview }
        return preview.isEmpty ? people : "\(people) · \(preview)"
    }

    static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if let week = calendar.date(byAdding: .day, value: -6, to: .now), date > week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Agott when a conversation is about no one in particular; the person when
/// it is about one; a small group when it is about several.
struct PeopleAvatar: View {
    var people: [String]
    var size: CGFloat = 42
    var onSpot = false
    /// The conversation's subject, for an avatar when it is about no one.
    var title: String?

    var body: some View {
        Group {
            switch people.count {
            case 0:
                if let title, !title.isEmpty {
                    InitialsAvatar(text: title, size: size)
                } else {
                    MascotFace(mood: .idle, size: size)
                }
            case 1:
                InitialsAvatar(text: people[0], size: size)
            default:
                ZStack(alignment: .topLeading) {
                    InitialsAvatar(text: people[0], size: size * 0.7)
                    InitialsAvatar(text: people[1], size: size * 0.7)
                        .overlay(Circle().strokeBorder(onSpot ? Ink.spot : Ink.canvas, lineWidth: 2))
                        .offset(x: size * 0.3, y: size * 0.3)
                    if people.count > 2 {
                        Text("+\(people.count - 2)")
                            .font(.system(size: size * 0.22, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Ink.spot))
                            .overlay(Capsule().strokeBorder(onSpot ? .white : Ink.canvas, lineWidth: 1.5))
                            .offset(x: size * 0.58, y: -2)
                    }
                }
                .frame(width: size, height: size, alignment: .topLeading)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(people.isEmpty ? "Agott" : people.joined(separator: ", ")))
    }
}

/// Earlier conversations, a click away from the chat (iPhone).
struct ConversationsButton: View {
    @State private var showing = false

    var body: some View {
        CandyIconButton(symbol: "clock.arrow.circlepath") { showing.toggle() }
            .help(Text("Conversations"))
            .sheet(isPresented: $showing) {
                NavigationStack {
                    ConversationSidebar()
                        .toolbar { Button("Done") { showing = false } }
                }
            }
    }
}

/// Someone without a photo, drawn the Agott way: a paper circle, an ink
/// line, and their initials lettered in Mochiy Pop One, like the mascot.
struct InitialsAvatar: View {
    var text: String
    var size: CGFloat
    var highlighted = false

    private var initials: String {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 || $0.first?.isUppercase == true }
        let letters = (words.isEmpty ? [text] : words).prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    var body: some View {
        Circle()
            .fill(Ink.paper)
            .overlay {
                // Their WhatsApp photo when there is one, inside the same
                // ink ring; the lettered initials otherwise.
                if let photo = ContactPhotos.shared.image(for: text) {
                    photo.resizable().scaledToFill().clipShape(Circle())
                } else {
                    Text(initials)
                        .font(Lettering.display(size * 0.36))
                        .foregroundStyle(Ink.faceInk)
                        .minimumScaleFactor(0.6)
                }
            }
            .overlay(Circle().strokeBorder(highlighted ? Ink.spot : Ink.faceInk, lineWidth: max(1.2, size * 0.035)))
            .frame(width: size, height: size)
    }
}

/// A conversation's time, the messenger way: the hour today, the weekday
/// this week, the date before that.
enum ConversationTime {
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
        if let week = calendar.date(byAdding: .day, value: -6, to: .now), date > week {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension String {
    /// Markdown as plain words for one-line previews: no stars, hashes,
    /// backticks, bullets or link syntax, one line. Copes with markers cut
    /// in half by truncation ("**muito").
    var markdownStripped: String {
        var text = self
        // [label](url) → label
        text = text.replacing(/\[([^\]]*)\]\([^)]*\)?/) { String($0.1) }
        // Line starts: headings, quotes, bullets, numbered lists.
        text = text.replacing(/(?m)^\s*(#{1,6}\s+|>\s?|[-*+•]\s+|\d+[.)]\s+)/, with: "")
        // Emphasis and code markers, matched or not.
        text = text.replacing(/\*\*|__|~~|`+/, with: "")
        text = text.replacing(/(^|\s)[*_](?=\S)/) { String($0.1) }
        text = text.replacing(/(\S)[*_](?=\s|$)/) { String($0.1) }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacing(/\s{2,}/, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
