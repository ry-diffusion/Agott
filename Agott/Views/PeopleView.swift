import Charts
import SwiftUI

/// People, shared by the list in the sidebar and the detail beside it.
@Observable
final class PeopleStore {
    static let shared = PeopleStore()

    private(set) var rows: [PeopleView.Row] = []
    var selection: String?
    private(set) var loading = false
    var showGroups = false
    var search = ""
    private(set) var circles: [PeopleCircle] = []
    var circle: String?
    private(set) var detecting = false
    @ObservationIgnored private var lastLoad = Date.distantPast
    @ObservationIgnored private var reloading: Task<Void, Never>?

    private init() {}

    var filtered: [PeopleView.Row] {
        var result = search.isEmpty ? rows : rows.filter { $0.chat.name.folded.contains(search.folded) }
        if let circle, let members = circles.first(where: { $0.id == circle })?.members {
            let names = Set(members.map(\.folded))
            result = result.filter { names.contains($0.chat.name.folded) }
        }
        return result
    }

    var selected: PeopleView.Row? { rows.first { $0.id == selection } }

    /// First look: load once, and the circles.
    func prepare() async {
        if circles.isEmpty { circles = await Circles.cached() }
        if rows.isEmpty && !loading { await load() }
    }

    /// New messages change who needs you; reload at most every 15 seconds.
    func reloadIfStale() {
        guard reloading == nil, Date().timeIntervalSince(lastLoad) > 15 else { return }
        reloading = Task {
            await load()
            circles = await Circles.cached()
            reloading = nil
        }
    }

    func detectCircles() async {
        detecting = true
        circles = (try? await Circles.refresh()) ?? circles
        detecting = false
    }

    /// Read rows sorted by who needs you; rows not read yet in this pass
    /// keep their place from the last one, so the list never empties.
    private static func ordered(_ fresh: [PeopleView.Row], keeping previous: [PeopleView.Row]) -> [PeopleView.Row] {
        let seen = Set(fresh.map(\.id))
        return fresh.sorted { $0.stats.attention > $1.stats.attention } + previous.filter { !seen.contains($0.id) }
    }

    func load() async {
        lastLoad = .now
        loading = true
        defer { loading = false }
        let chats = (try? await MemoryStore.shared.chats(
            limit: 150, includeGroups: showGroups, since: Date().addingTimeInterval(-365 * 86400))) ?? []
        // Reading every chat can take a while on a cold start; show people
        // as they are read.
        let current = Set(chats.map(\.id))
        let before = rows.filter { current.contains($0.id) }
        var result: [PeopleView.Row] = []
        var published = Date.distantPast
        for chat in chats where chat.messageCount >= 3 {
            guard !Task.isCancelled else { break }
            result.append(PeopleView.Row(chat: chat, stats: await RelationshipAnalyzer.stats(for: chat)))
            if Date().timeIntervalSince(published) > 0.4 {
                published = .now
                rows = Self.ordered(result, keeping: before)
            }
        }
        rows = Self.ordered(result, keeping: before)
        if selection == nil, LaunchOptions.selectFirst { selection = rows.first?.id }
    }
}

/// The person you picked in the sidebar: how things stand, and help to answer.
struct PeopleView: View {
    struct Row: Identifiable, Hashable {
        var chat: ChatSummary
        var stats: RelationshipStats
        var id: String { chat.id }
        /// How the message watcher names this chat.
        var followUpKey: String { "\(chat.source.rawValue)|\(chat.chatID)" }
    }

    @State private var store = PeopleStore.shared

    var body: some View {
        Group {
            if let row = store.selected {
                VStack(alignment: .leading, spacing: 0) {
                    // Back to everyone, like a notebook's back arrow.
                    HStack {
                        if Navigator.shared.zen { SidebarToggle() }
                        Button { withAnimation(Motion.settle) { store.selection = nil } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                                Image(systemName: "person.2")
                            }
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(HoverIconStyle(size: 30))
                        .quietSurface(Capsule(), fill: .clear)
                        .keyboardShortcut(.cancelAction)
                        .tip("Back to People", edge: .bottom)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: WindowBar.height)
                    PersonDetail(row: row)
                        .id(row.id)
                        .padding(.horizontal, 28)
                }
            } else {
                PeopleTable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.prepare() }
        .onChange(of: Indexer.shared.totals.messages) { _, _ in store.reloadIfStale() }
    }
}

/// Everyone, as a table: who, when you last talked, how much, and which way
/// it is going. Pills filter by who is waiting, groups and circles.
struct PeopleTable: View {
    @State private var store = PeopleStore.shared
    @State private var waitingOnly = false
    @State private var searching = false

    private var rows: [PeopleView.Row] {
        guard waitingOnly else { return store.filtered }
        return store.filtered.filter {
            $0.stats.awaitingMyReply || FollowUpCenter.shared.item(for: $0.followUpKey)?.matters == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if Navigator.shared.zen { SidebarToggle() }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: WindowBar.height)

            HStack(alignment: .center, spacing: 8) {
                Text("People")
                    .font(Lettering.display(34, relativeTo: .largeTitle))
                    .foregroundStyle(Ink.text)
                Spacer()
                if searching {
                    TextField(String(localized: "Search people"), text: $store.search)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .quietSurface(Capsule(), fill: Ink.raised)
                        .frame(width: 200)
                }
                Button { searching.toggle(); if !searching { store.search = "" } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(HoverIconStyle(size: 30))
                .quietSurface(Circle(), fill: .clear)
                .tip("Search people", edge: .bottom)
            }
            .padding(.horizontal, 28)

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    FilterChip(title: "Everyone", selected: !waitingOnly && store.circle == nil && !store.showGroups) {
                        waitingOnly = false; store.circle = nil
                        if store.showGroups { store.showGroups = false; Task { await store.load() } }
                    }
                    FilterChip(title: "Waiting for you", selected: waitingOnly) { waitingOnly.toggle() }
                    FilterChip(title: "Groups", selected: store.showGroups) {
                        store.showGroups.toggle()
                        Task { await store.load() }
                    }
                    ForEach(store.circles) { item in
                        FilterChip(title: LocalizedStringKey(item.name), selected: store.circle == item.id) {
                            store.circle = store.circle == item.id ? nil : item.id
                        }
                    }
                    Button { Task { await store.detectCircles() } } label: {
                        Image(systemName: store.detecting ? "hourglass" : "sparkles")
                    }
                    .buttonStyle(HoverIconStyle(size: 28))
                    .disabled(store.detecting)
                    .tip(store.circles.isEmpty ? "Find my circles" : "Refresh circles", edge: .bottom)
                }
                .padding(.horizontal, 28)
            }
            .scrollIndicators(.never)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Column titles.
            HStack(spacing: 12) {
                Text("Person").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 52)
                Text("Last message").frame(width: 130, alignment: .leading)
                Text("Messages").frame(width: 90, alignment: .trailing)
                Text("Trend").frame(width: 60, alignment: .center)
            }
            .font(.callout)
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 28)
            .padding(.vertical, 8)
            Rectangle().fill(Ink.hairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        PeopleTableRow(row: row) {
                            withAnimation(Motion.settle) { store.selection = row.id }
                        }
                        Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1).padding(.leading, 80)
                    }
                    if rows.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "person.2").font(.system(size: 26)).foregroundStyle(Ink.muted)
                            Text(store.loading ? "Reading your chats…" : "No one here yet")
                                .font(.callout).foregroundStyle(Ink.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .background(Ink.canvas)
    }
}

/// One person in the table.
private struct PeopleTableRow: View {
    var row: PeopleView.Row
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        let hidden = AppSettings.shared.hideNames
        Button(action: open) {
            HStack(spacing: 12) {
                Avatar(name: hidden ? "?" : row.chat.name, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(hidden ? String(localized: "Someone") : row.chat.name)
                            .font(.system(size: 14)).foregroundStyle(Ink.text).lineLimit(1)
                        Image(systemName: row.chat.source.symbol).font(.caption2).foregroundStyle(Ink.muted)
                    }
                    Group {
                        if let followUp = FollowUpCenter.shared.item(for: row.followUpKey), followUp.matters {
                            Text("Waiting for your reply").foregroundStyle(Ink.spot)
                        } else {
                            Text(hidden ? "" : row.chat.lastText).foregroundStyle(Ink.muted)
                        }
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(ConversationTime.short(row.chat.lastDate))
                    .font(.callout).foregroundStyle(Ink.text)
                    .frame(width: 130, alignment: .leading)
                Text(row.chat.messageCount, format: .number)
                    .font(.callout).monospacedDigit().foregroundStyle(Ink.text)
                    .frame(width: 90, alignment: .trailing)
                TrendBadge(trend: row.stats.trend).frame(width: 60)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(Ink.text.opacity(hovering ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// People in the sidebar's list column, the way chats are listed: search,
/// circles to filter by, who is waiting for you, then everyone else.
struct PeopleList: View {
    @State private var store = PeopleStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                    TextField(String(localized: "Search people"), text: $store.search).textFieldStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Ink.text.opacity(0.07)))
                Button { store.showGroups.toggle() } label: {
                    Image(systemName: store.showGroups ? "person.3.fill" : "person.3")
                        .foregroundStyle(store.showGroups ? Ink.spot : Ink.muted)
                }
                .buttonStyle(HoverIconStyle(size: 30))
                .tip(store.showGroups ? "Hide groups" : "Include groups")
            }

            circles

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let waiting = store.filtered.filter {
                        $0.stats.awaitingMyReply || FollowUpCenter.shared.item(for: $0.followUpKey)?.matters == true
                    }
                    if !waiting.isEmpty {
                        header("Waiting for you")
                        ForEach(waiting) { row in rowButton(row) }
                    }
                    let others = store.filtered.filter { row in !waiting.contains { $0.id == row.id } }
                    if !others.isEmpty && !waiting.isEmpty { header(store.showGroups ? "Chats" : "Everyone else") }
                    ForEach(others) { row in rowButton(row) }
                    if store.rows.isEmpty {
                        HStack(spacing: 8) {
                            if store.loading { ProgressView().controlSize(.small) }
                            Text(store.loading ? "Reading your chats…" : "No conversations yet")
                                .font(.callout).foregroundStyle(Ink.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .task { await store.prepare() }
        .onChange(of: store.showGroups) { _, _ in Task { await store.load() } }
        .onChange(of: Indexer.shared.totals.messages) { _, _ in store.reloadIfStale() }
    }

    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Ink.muted)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// Circles to filter by, small enough to sit above the list.
    private var circles: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip(id: nil, name: String(localized: "Everyone"), count: store.rows.count)
                ForEach(store.circles) { item in
                    chip(id: item.id, name: item.name, count: item.members.count)
                        .help(Text(item.why.isEmpty ? item.groups.joined(separator: ", ") : item.why))
                }
                Button {
                    Task { await store.detectCircles() }
                } label: {
                    Image(systemName: store.detecting ? "hourglass" : "sparkles")
                }
                .buttonStyle(HoverIconStyle(size: 26))
                .disabled(store.detecting)
                .tip(store.circles.isEmpty ? "Find my circles" : "Refresh circles")
            }
        }
        .scrollIndicators(.never)
    }

    private func chip(id: String?, name: String, count: Int) -> some View {
        let selected = store.circle == id
        return Button {
            withAnimation(Motion.settle) { store.circle = id }
        } label: {
            HStack(spacing: 4) {
                Text(name).lineLimit(1)
                Text(count, format: .number).monospacedDigit().opacity(0.7)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? AnyShapeStyle(Ink.spot) : AnyShapeStyle(Ink.text.opacity(0.07))))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }

    private func rowButton(_ row: PeopleView.Row) -> some View {
        Button {
            withAnimation(Motion.settle) { store.selection = row.id }
        } label: {
            PersonRow(row: row, selected: store.selection == row.id)
        }
        .buttonStyle(.plain)
    }
}

private struct PersonRow: View {
    var row: PeopleView.Row
    var selected: Bool

    /// What Jev thinks this chat needs from you, in a few words.
    private func followUpHint(_ followUp: FollowUp) -> String {
        if followUp.askAgain >= 0.6 && followUp.askAgain >= followUp.needsReply { return String(localized: "Ask again") }
        if followUp.openQuestion >= 0.6 { return String(localized: "A question is waiting") }
        return String(localized: "Needs a reply")
    }

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: row.chat.name, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(row.chat.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Image(systemName: row.chat.source.symbol).font(.caption2).opacity(0.6)
                    Spacer(minLength: 4)
                    Text(ConversationTime.short(row.chat.lastDate)).font(.system(size: 11.5)).opacity(0.7)
                }
                HStack(spacing: 4) {
                    if let followUp = FollowUpCenter.shared.item(for: row.followUpKey), followUp.matters {
                        Label(followUpHint(followUp), systemImage: followUp.askAgain >= 0.6 ? "arrow.uturn.backward" : "bubble.left")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.spot))
                    } else {
                        Text(row.chat.lastText).font(.system(size: 12.5)).opacity(0.75)
                    }
                    Spacer(minLength: 4)
                    TrendBadge(trend: row.stats.trend)
                }
                .lineLimit(1)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(Ink.spot) : AnyShapeStyle(Ink.text.opacity(hovering ? 0.06 : 0))))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct TrendBadge: View {
    var trend: RelationshipStats.Trend

    var body: some View {
        let symbol = switch trend {
        case .warming: "flame.fill"
        case .steady: "equal"
        case .cooling: "snowflake"
        case .quiet: "moon.zzz.fill"
        }
        Image(systemName: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(trend == .warming ? Ink.spot : Ink.text)
            .help(Text(trend.label))
            .accessibilityLabel(Text(trend.label))
    }
}

private struct PersonDetail: View {
    var row: PeopleView.Row
    @Environment(\.colorScheme) private var scheme
    // Charts draws with resolved colours, so the bars get concrete ones.
    static let chartInkDark = Color(.sRGB, red: 0.93, green: 0.92, blue: 0.90)
    static let chartInkLight = Color(.sRGB, red: 0.08, green: 0.07, blue: 0.10)
    @State private var read: Card.PersonRead?
    @State private var readDate: Date?
    @State private var replies: Card.Replies?
    @State private var intent = ""
    @State private var working: String?
    @State private var error: String?
    @State private var consistency: Card.Consistency?
    /// Jev's reading of how they feel lately; the word tagger until it answers.
    @State private var feeling: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Who, and what you can do about it: the same header as Home
                // and the chat, actions on the right.
                HStack(alignment: .center, spacing: 14) {
                    Avatar(name: row.chat.name, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.chat.name)
                            .font(Lettering.display(30, relativeTo: .title))
                            .foregroundStyle(Ink.text)
                            .lineLimit(1)
                        Text("\(row.chat.source.displayName) · \(row.chat.messageCount) messages since \(row.chat.firstDate.formatted(.dateTime.month().year()))")
                            .font(.callout).foregroundStyle(Ink.muted)
                    }
                    Spacer(minLength: 12)
                    Button { Task { await runConsistency() } } label: {
                        Label(consistency == nil ? "Face to face vs behind their back" : "Check again", systemImage: "theatermasks")
                    }
                    .buttonStyle(.candy(.soft, compact: true))
                    .help(Text("Compare how you talk to them with how you talk about them elsewhere"))
                    Button { Task { await runRead() } } label: {
                        Label(read == nil ? "Read our story" : "Read again", systemImage: "sparkles")
                    }
                    .buttonStyle(.candy(.primary, compact: true))
                }
                .padding(.bottom, 4)

                if let working {
                    HStack(spacing: 8) {
                        ThinkingOrb(mode: .orbits, size: 18)
                        Text(working).font(.callout).foregroundStyle(Ink.text).modifier(Shimmer(active: true))
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Ink.text)
                }

                if row.stats.awaitingMyReply {
                    SettingsCard {
                        SettingsRow(symbol: "clock",
                                    title: "Waiting for your reply since \(row.stats.waitingSince ?? .now, format: .relative(presentation: .named))",
                                    verbatim: row.stats.lastQuestionFromThem.map { "“\($0)”" } ?? String(localized: "Their last message is still unanswered.")) {
                            Circle().fill(Ink.spot).frame(width: 8, height: 8)
                        }
                    }
                }

                SectionHeading(title: "How you talk")
                statsGrid
                activityChart

                if let read {
                    SectionHeading(title: "Your story")
                    PersonCard(card: read)
                    if let readDate {
                        Text("Read \(readDate, format: .relative(presentation: .named))").font(.caption).foregroundStyle(Ink.muted)
                    }
                }

                SectionHeading(title: "Help me answer")
                HStack(spacing: 8) {
                    TextField(String(localized: "What do you want to say? (optional)"), text: $intent, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .lineLimit(1...4)
                        .onSubmit { Task { await suggest() } }
                    Button { Task { await suggest() } } label: {
                        Label("Suggest replies", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.candy(.soft, compact: true))
                }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .frame(minHeight: 50)
                .quietSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
                if let replies { RepliesCard(card: replies) }

                if let consistency {
                    SectionHeading(title: "Face to face vs behind their back")
                    ConsistencyCard(card: consistency)
                }
            }
            .padding(.bottom, 30)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .disabled(working != nil)
        .task {
            if let (card, date) = await RelationshipAnalyzer.cachedRead(row.chat) { read = card; readDate = date }
            consistency = await Consistency.cached(row.chat)
            feeling = await ChatMood.judge(row.chat)
            if LaunchOptions.runRead { await runRead() }
        }
    }

    /// How you talk, as a two-column table of plain facts.
    private var statsGrid: some View {
        let stats = row.stats
        let pairs: [(String, LocalizedStringKey, String)] = [
            ("pencil.line", "You write", "\(Int(stats.balance * 100))%"),
            ("bolt", "You reply in", minutes(stats.myReplyMinutes)),
            ("calendar", "Last 30 days", "\(stats.last30)"),
            ("tortoise", "They reply in", minutes(stats.theirReplyMinutes)),
            ("hand.wave", "Who starts", "\(stats.myInitiations) : \(stats.theirInitiations)"),
            (mood(feeling ?? stats.theirSentiment), "Mood", moodWord(feeling ?? stats.theirSentiment)),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<3, id: \.self) { line in
                if line > 0 {
                    Rectangle().fill(Ink.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    Metric(symbol: pairs[line * 2].0, title: pairs[line * 2].1, value: pairs[line * 2].2)
                    Rectangle().fill(Ink.hairline).frame(width: 1).gridCellUnsizedAxes(.vertical)
                    Metric(symbol: pairs[line * 2 + 1].0, title: pairs[line * 2 + 1].1, value: pairs[line * 2 + 1].2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A chat younger than three weeks is one tall bar by the week;
            // by the day it shows how it actually went.
            let byDay = Date().timeIntervalSince(row.chat.firstDate) < 21 * 86400
            let counts = byDay ? row.stats.daily : row.stats.weekly
            let peak = max(1, counts.max() ?? 1)
            Text(byDay ? "Messages per day" : "Messages per week").font(.callout).foregroundStyle(Ink.muted)
            Chart(Array(counts.enumerated()), id: \.offset) { index, count in
                // Empty stretches keep a faint stub so the timeline reads as one.
                BarMark(x: .value("Period", String(index)), y: .value("Messages", max(Double(count), Double(peak) * 0.03)),
                        width: .ratio(0.62))
                    // Grey bars; the purple marks the period you are in now.
                    .foregroundStyle(index == counts.count - 1 ? spot : (scheme == .dark ? Self.chartInkDark : Self.chartInkLight).opacity(0.32))
                    .opacity(count == 0 ? 0.5 : 1)
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 90)
            HStack {
                Text(byDay ? "2 weeks ago" : "12 weeks ago")
                Spacer()
                Text(byDay ? "Today" : "This week")
            }
            .font(.caption2)
            .foregroundStyle(Ink.muted)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .padding(16)
        .quietSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Ink.spot (the system purple) as a concrete colour, which Charts needs.
    private var spot: Color {
        scheme == .dark ? Color(.sRGB, red: 0.749, green: 0.353, blue: 0.949) : Color(.sRGB, red: 0.686, green: 0.322, blue: 0.871)
    }

    private func minutes(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(localized: "under a minute") }
        if value < 60 { return "\(Int(value)) min" }
        if value < 60 * 24 { return "\(Int(value / 60)) h" }
        return "\(Int(value / 1440)) d"
    }

    private func mood(_ value: Double) -> String { value > 0.25 ? "sun.max" : value < -0.2 ? "cloud.rain" : "cloud.sun" }

    private func moodWord(_ value: Double) -> String {
        value > 0.25 ? String(localized: "Sunny") : value < -0.2 ? String(localized: "Cloudy") : String(localized: "Fine")
    }

    private func runRead() async {
        working = String(localized: "Reading your conversation…")
        error = nil
        do {
            read = try await RelationshipAnalyzer.read(row.chat, stats: row.stats)
            readDate = .now
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }

    private func runConsistency() async {
        working = String(localized: "Comparing what you say to them and about them…")
        error = nil
        do {
            consistency = try await Consistency.check(row.chat)
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }

    private func suggest() async {
        working = String(localized: "Thinking about what to say…")
        error = nil
        do {
            replies = try await RelationshipAnalyzer.replies(for: row.chat, intent: intent.isEmpty ? nil : intent)
        } catch {
            self.error = error.localizedDescription
        }
        working = nil
    }
}

private struct Metric: View {
    var symbol: String
    var title: LocalizedStringKey
    var value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Ink.muted).frame(width: 18)
            Text(title).font(.callout).foregroundStyle(Ink.muted)
            Spacer(minLength: 8)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().foregroundStyle(Ink.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }
}

extension RelationshipStats.Trend {
    var label: String {
        switch self {
        case .warming: String(localized: "Warming up")
        case .steady: String(localized: "Steady")
        case .cooling: String(localized: "Cooling down")
        case .quiet: String(localized: "Quiet")
        }
    }
}
