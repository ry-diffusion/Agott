import EventKit
import SwiftUI

/// Home: what is coming up on your calendar, your conversations by day, and
/// a box to ask anything, which starts a new conversation.
struct HomeView: View {
    @State private var agent = Agent.shared
    @State private var navigator = Navigator.shared
    @State private var settings = AppSettings.shared
    @State private var events: [Upcoming] = []
    @State private var calendarAllowed = Organizer.shared.calendarAuthorized

    static let column: CGFloat = 720

    struct Upcoming: Identifiable, Hashable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var calendarColor: Color
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Coming up")
                    .font(Lettering.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(Ink.text)
                    .padding(.top, 8)
                calendarCard
                recents
            }
            .frame(maxWidth: Self.column, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        // Content slides under the bars and blurs softly, no line.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .safeAreaBar(edge: .top, spacing: 0) { topBar }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            AskBox(suggestions: true) { text in
                navigator.section = .chat
                agent.newConversation()
                agent.send(text)
            }
            .frame(maxWidth: Self.column + 40)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity)
        }
        .task { await loadEvents() }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if navigator.zen { SidebarToggle() }
            Spacer()
            Button {
                navigator.section = .chat
                withAnimation(Motion.settle) { agent.newConversation() }
            } label: {
                Label("New conversation", systemImage: "plus")
            }
            .buttonStyle(.candy(.soft, compact: true))
        }
        .padding(.horizontal, 14)
        .frame(height: WindowBar.height)
        .titleBar()
    }

    // MARK: Calendar

    private var calendarCard: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Date.now, format: .dateTime.day())
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundStyle(Ink.text)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text(Date.now, format: .dateTime.month(.wide))
                                .font(.callout.weight(.medium))
                            Circle().fill(Ink.spot).frame(width: 5, height: 5)
                        }
                        Text(Date.now, format: .dateTime.weekday(.abbreviated))
                            .font(.callout)
                            .foregroundStyle(Ink.muted)
                    }
                    .foregroundStyle(Ink.text)
                }
            }
            .frame(width: 170, alignment: .leading)

            Group {
                if !calendarAllowed {
                    emptyCalendar(title: "Your calendar isn't connected",
                                  detail: "Agott reads it on this Mac to know what's coming up.",
                                  action: "Connect calendar") {
                        Task {
                            _ = await Organizer.shared.requestAccess()
                            calendarAllowed = Organizer.shared.calendarAuthorized
                            await loadEvents()
                        }
                    }
                } else if events.isEmpty {
                    emptyCalendar(title: "Nothing coming up",
                                  detail: "No events in the next three days.",
                                  action: "Open Calendar") { openCalendar() }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groupedEvents, id: \.day) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.dayName(group.day))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Ink.muted)
                                ForEach(group.items) { event in
                                    HStack(spacing: 10) {
                                        Capsule().fill(event.calendarColor).frame(width: 3, height: 26)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(event.title).font(.callout).foregroundStyle(Ink.text).lineLimit(1)
                                            Text(event.allDay ? String(localized: "All day") : Self.span(event))
                                                .font(.caption).foregroundStyle(Ink.muted).monospacedDigit()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func emptyCalendar(title: LocalizedStringKey, detail: LocalizedStringKey, action: LocalizedStringKey,
                               perform: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 20))
                .foregroundStyle(Ink.muted)
            Text(title).font(.callout).foregroundStyle(Ink.text)
            Text(detail).font(.caption).foregroundStyle(Ink.muted)
            Button(action, action: perform)
                .buttonStyle(.candy(.soft, compact: true))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private var groupedEvents: [(day: Date, items: [Upcoming])] {
        let calendar = Calendar.current
        var result: [(day: Date, items: [Upcoming])] = []
        for event in events.prefix(6) {
            let day = calendar.startOfDay(for: event.start)
            if let last = result.indices.last, result[last].day == day {
                result[last].items.append(event)
            } else {
                result.append((day, [event]))
            }
        }
        return result
    }

    private func loadEvents() async {
        guard Organizer.shared.calendarAuthorized else { return }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: start)) ?? start
        let found = (try? await Organizer.shared.events(from: start, to: end)) ?? []
        events = found.map { event in
            Upcoming(id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? String(localized: "Event"),
                     start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                     calendarColor: event.calendar.map { Color(cgColor: $0.cgColor) } ?? Ink.muted)
        }
    }

    private func openCalendar() {
        #if os(macOS)
        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
        #endif
    }

    static func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    static func span(_ event: Upcoming) -> String {
        "\(event.start.formatted(.dateTime.hour().minute())) – \(event.end.formatted(.dateTime.hour().minute()))"
    }

    // MARK: Conversations

    private var dayGroups: [(day: Date, items: [ConversationInfo])] {
        let calendar = Calendar.current
        var result: [(day: Date, items: [ConversationInfo])] = []
        for item in agent.conversations.prefix(40) {
            let day = calendar.startOfDay(for: item.updated)
            if let last = result.indices.last, result[last].day == day {
                result[last].items.append(item)
            } else {
                result.append((day, [item]))
            }
        }
        return result
    }

    @ViewBuilder
    private var recents: some View {
        if agent.conversations.isEmpty {
            Text("Your conversations with Agott will show up here.")
                .font(.callout)
                .foregroundStyle(Ink.muted)
                .padding(.top, 20)
        } else {
            ForEach(dayGroups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Ink.muted)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    ForEach(group.items) { item in
                        ConversationLine(item: item) {
                            navigator.section = .chat
                            withAnimation(Motion.settle) { agent.open(item.id) }
                        }
                    }
                }
            }
        }
    }
}

/// A conversation as a line on Home: an icon, its title, who it is about
/// (or how it ended), and the time.
private struct ConversationLine: View {
    var item: ConversationInfo
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        let hidden = AppSettings.shared.hideNames
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.muted)
                    .frame(width: 34, height: 34)
                    .quietSurface(RoundedRectangle(cornerRadius: 8, style: .continuous), fill: Ink.raised)
                VStack(alignment: .leading, spacing: 2) {
                    Text(EntityText.plain(item.displayTitle, hidden: hidden))
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    Text(subtitle(hidden: hidden))
                        .font(.callout)
                        .foregroundStyle(Ink.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(item.updated, format: .dateTime.hour().minute())
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Ink.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Ink.text.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            Button("Delete conversation", systemImage: "trash", role: .destructive) {
                withAnimation(Motion.settle) { Agent.shared.delete(item.id) }
            }
        }
    }

    private func subtitle(hidden: Bool) -> String {
        let people = EntityText.plain((item.people ?? []).joined(separator: ", "), hidden: hidden)
        if !people.isEmpty { return people }
        let preview = EntityText.plain(item.preview.markdownStripped, hidden: hidden)
        return preview.isEmpty ? String(localized: "Agott") : preview
    }
}

/// Brings the sidebar back when it is tucked away.
/// Room in a top bar for the sidebar and search buttons that stay beside
/// the window buttons while the sidebar is hidden (drawn by the window).
struct SidebarToggle: View {
    static let width: CGFloat = WindowBar.afterButtons + 66
    var body: some View {
        Color.clear.frame(width: Self.width, height: 1)
    }
}

/// The box you ask Agott in, on Home: suggestions above it, then a field
/// with the model, attachments and the mic.
struct AskBox: View {
    var suggestions = false
    var send: (String) -> Void
    @State private var draft = ""
    @State private var picks: [(symbol: String, text: String)] = []
    @State private var dictation = Dictation.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if suggestions && !picks.isEmpty {
                HStack(spacing: 6) {
                    ForEach(picks.prefix(3), id: \.text) { item in
                        Button { send(item.text) } label: {
                            Label(item.text, systemImage: item.symbol)
                                .font(.callout)
                                .lineLimit(1)
                                .foregroundStyle(Ink.muted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 8, inset: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            HStack(spacing: 8) {
                // While the mic is on, the field shows what is being heard.
                TextField(dictation.isRunning ? dictation.hint : String(localized: "Ask anything"),
                          text: dictation.isRunning ? .constant(dictation.transcript) : $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit(submit)
                ModelButton()
                HoldToTalkButton { text in send(text) }
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 52)
            .quietSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .background {
            if suggestions {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Ink.sidebar)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Ink.hairline, lineWidth: 1))
            }
        }
        .task {
            if suggestions { picks = await ChatSuggestions.load() }
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }
}

/// The chat model's name, small; click to pick another.
struct ModelButton: View {
    @State private var settings = AppSettings.shared
    @State private var catalog = ModelCatalog.shared
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 3) {
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.callout)
            .padding(.horizontal, 6)
        }
        .buttonStyle(HoverIconStyle(size: 30))
        .tip("Choose the chat model", edge: .top)
        .sheet(isPresented: $open) {
            ModelPicker(provider: $settings.provider, model: $settings.modelName, allowsSame: false)
        }
    }

    private var label: String {
        switch settings.provider {
        case .onDevice, .privateCloud: settings.provider.title
        case .openCode: catalog.model(settings.modelName)?.name ?? settings.modelName
        }
    }
}

/// Things worth asking, from your own memory first.
enum ChatSuggestions {
    static func load() async -> [(symbol: String, text: String)] {
        var result: [(String, String)] = []
        let recent = (try? await MemoryStore.shared.chats(limit: 40, includeGroups: false,
                                                          since: Date().addingTimeInterval(-3 * 86400))) ?? []
        for chat in recent where !chat.lastFromMe && !GraphView.isPhoneOnly(chat.name) {
            result.append(("arrowshape.turn.up.left", String(localized: "How should I answer \(chat.name)?")))
            if result.count == 1 { break }
        }
        result += [
            ("person.2", String(localized: "Who's waiting for a reply from me?")),
            ("sun.max", String(localized: "How was my day?")),
            ("calendar", String(localized: "What's on my calendar tomorrow?")),
            ("music.note", String(localized: "What does my music say about my mood?")),
        ]
        return Array(result.prefix(5))
    }
}
