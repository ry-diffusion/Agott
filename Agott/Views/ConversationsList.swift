import SwiftUI

/// Your conversations with Agott, the way a messenger lists chats: who it is
/// about, what it is about, and how it ended.
struct ConversationSidebar: View {
    @State private var agent = Agent.shared
    @State private var query = ""

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
            HStack {
                Text("Chats").font(Lettering.display(20, relativeTo: .title3)).foregroundStyle(Ink.text)
                Spacer()
                Button {
                    withAnimation(Motion.settle) { agent.newConversation() }
                } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(HoverIconStyle(size: 30))
                .keyboardShortcut("n", modifiers: .command)
                .help(Text("New conversation"))
            }
            .padding(.horizontal, 6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                TextField(String(localized: "Search"), text: $query).textFieldStyle(.plain)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(Ink.text.opacity(0.06)))

            ScrollView {
                LazyVStack(spacing: 2) {
                    if isDraft && query.isEmpty {
                        ConversationRow(
                            info: ConversationInfo(id: agent.currentID, title: String(localized: "New conversation"),
                                                   preview: "", updated: .now),
                            selected: true) {}
                    }
                    ForEach(shown) { item in
                        ConversationRow(info: item, selected: item.id == agent.currentID) {
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
        .padding(.horizontal, 10)
        .padding(.top, 18)
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
                PeopleAvatar(people: info.people ?? [], size: 42, onSpot: selected)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(info.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.time(info.updated))
                            .font(.caption)
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(Ink.muted))
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(Ink.muted))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
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
        let people = (info.people ?? []).joined(separator: ", ")
        let preview = info.preview.replacingOccurrences(of: "\n", with: " ")
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

    var body: some View {
        Group {
            switch people.count {
            case 0:
                MascotFace(mood: .idle, size: size)
            case 1:
                Avatar(name: people[0], size: size)
            default:
                ZStack(alignment: .topLeading) {
                    Avatar(name: people[0], size: size * 0.7)
                    Avatar(name: people[1], size: size * 0.7)
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
