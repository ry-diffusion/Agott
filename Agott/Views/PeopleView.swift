import Charts
import SwiftUI

/// Everyone you talk to, ordered by who needs you.
struct PeopleView: View {
    @State private var rows: [Row] = []
    @State private var selection: String?
    @State private var loading = false
    @State private var showGroups = false
    @State private var search = ""
    @State private var circles: [PeopleCircle] = []
    @State private var circle: String?
    @State private var detecting = false
    @State private var reloading: Task<Void, Never>?
    @State private var lastLoad = Date.distantPast

    struct Row: Identifiable, Hashable {
        var chat: ChatSummary
        var stats: RelationshipStats
        var id: String { chat.id }
        /// How the message watcher names this chat.
        var followUpKey: String { "\(chat.source.rawValue)|\(chat.chatID)" }
    }

    private var filtered: [Row] {
        var result = search.isEmpty ? rows : rows.filter { $0.chat.name.folded.contains(search.folded) }
        if let circle, let members = circles.first(where: { $0.id == circle })?.members {
            let names = Set(members.map(\.folded))
            result = result.filter { names.contains($0.chat.name.folded) }
        }
        return result
    }

    private var circleBar: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    circleChip(id: nil, name: String(localized: "Everyone"), symbol: "person.3", count: rows.count)
                    ForEach(circles) { item in
                        circleChip(id: item.id, name: item.name, symbol: item.kind.symbol, count: item.members.count)
                            .help(Text(item.why.isEmpty ? item.groups.joined(separator: ", ") : item.why))
                    }
                    Button {
                        Task { await detectCircles() }
                    } label: {
                        Label(detecting ? "Finding circles…" : (circles.isEmpty ? "Find my circles" : "Refresh circles"),
                              systemImage: "sparkles")
                    }
                    .buttonStyle(.candy(.soft, compact: true))
                    .disabled(detecting)
                }
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.never)
    }

    private func circleChip(id: String?, name: String, symbol: String, count: Int) -> some View {
        let selected = circle == id
        return Button {
            withAnimation(Motion.settle) { circle = id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption.weight(.bold))
                Text(name).font(.callout.weight(.semibold))
                Text(count, format: .number).font(.caption.weight(.bold)).monospacedDigit().opacity(0.7)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.text))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(selected ? .regular.tint(Ink.spot).interactive() : .regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
    }

    private func detectCircles() async {
        detecting = true
        circles = (try? await Circles.refresh()) ?? circles
        detecting = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(title: "People", subtitle: "Who needs you, and how things stand.", symbol: "heart") {
                HStack(spacing: 8) {
                    Toggle(isOn: $showGroups) { Label("Include groups", systemImage: "person.3.fill") }
                        .toggleStyle(.button)
                        .buttonStyle(.candy(showGroups ? .primary : .soft, compact: true))
                    CandyIconButton(symbol: "arrow.clockwise") { Task { await load() } }
                        .help(Text("Refresh"))
                }
            }

            circleBar

            HStack(alignment: .top, spacing: 18) {
                list.frame(width: 330)
                Group {
                    if let row = rows.first(where: { $0.id == selection }) {
                        PersonDetail(row: row).id(row.id)
                    } else {
                        VStack(spacing: 12) {
                            MascotAvatar(size: 96)
                            Text("Pick someone").font(Lettering.display(20, relativeTo: .title3)).foregroundStyle(Ink.text)
                            Text("See how things stand, and get help answering.").foregroundStyle(Ink.muted)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .task(id: showGroups) { await load() }
        .task { circles = await Circles.cached() }
        // New messages or a finished index change who needs you.
        // One reload at a time, at most every 15 seconds: indexing changes
        // the totals several times a second, and each reload reads every chat.
        .onChange(of: Indexer.shared.totals.messages) { _, _ in
            guard reloading == nil, Date().timeIntervalSince(lastLoad) > 15 else { return }
            reloading = Task {
                await load()
                circles = await Circles.cached()
                reloading = nil
            }
        }
        .onDisappear { reloading?.cancel(); reloading = nil }
    }

    private var list: some View {
        VStack(spacing: 10) {
            CandyField(placeholder: "Search people", text: $search, symbol: "magnifyingglass")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let waiting = filtered.filter { $0.stats.awaitingMyReply || FollowUpCenter.shared.item(for: $0.followUpKey)?.matters == true }
                    if !waiting.isEmpty {
                        PanelTitle(title: "Waiting for you", symbol: "clock.badge.exclamationmark").padding(.top, 4)
                        ForEach(waiting) { row in rowButton(row) }
                    }
                    let others = filtered.filter { row in !waiting.contains { $0.id == row.id } }
                    if !others.isEmpty || waiting.isEmpty {
                        PanelTitle(title: showGroups ? "Chats" : "People", symbol: "person.2").padding(.top, 10)
                    }
                    ForEach(others) { row in rowButton(row) }
                    if rows.isEmpty && loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading your chats…").font(.callout).foregroundStyle(Ink.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 30)
                    } else if rows.isEmpty && !loading {
                        VStack(spacing: 6) {
                            Text("No conversations yet").font(.headline).foregroundStyle(Ink.text)
                            Text("Turn on WhatsApp or iMessage in Memory and let Agott read them.")
                                .font(.caption).foregroundStyle(Ink.muted).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 30)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
    }

    private func rowButton(_ row: Row) -> some View {
        Button {
            withAnimation(Motion.settle) { selection = row.id }
        } label: {
            PersonRow(row: row, selected: selection == row.id)
        }
        .buttonStyle(PressScale())
    }

    /// Read rows sorted by who needs you; rows not read yet in this pass
    /// keep their place from the last one, so the list never empties.
    private static func ordered(_ fresh: [Row], keeping previous: [Row]) -> [Row] {
        let seen = Set(fresh.map(\.id))
        return fresh.sorted { $0.stats.attention > $1.stats.attention } + previous.filter { !seen.contains($0.id) }
    }

    private func load() async {
        lastLoad = .now
        loading = true
        defer { loading = false }
        let chats = (try? await MemoryStore.shared.chats(
            limit: 150, includeGroups: showGroups, since: Date().addingTimeInterval(-365 * 86400))) ?? []
        // Reading every chat can take a while on a cold start, especially
        // while Agott is learning; show people as they are read.
        let current = Set(chats.map(\.id))
        let before = rows.filter { current.contains($0.id) }
        var result: [Row] = []
        var published = Date.distantPast
        for chat in chats where chat.messageCount >= 3 {
            guard !Task.isCancelled else { break }
            result.append(Row(chat: chat, stats: await RelationshipAnalyzer.stats(for: chat)))
            if Date().timeIntervalSince(published) > 0.4 {
                published = .now
                rows = Self.ordered(result, keeping: before)
            }
        }
        rows = Self.ordered(result, keeping: before)
        if selection == nil, LaunchOptions.selectFirst { selection = rows.first?.id }
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

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: row.chat.name, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.chat.name).font(.body.weight(.bold)).foregroundStyle(Ink.text).lineLimit(1)
                    Image(systemName: row.chat.source.symbol).font(.caption2).foregroundStyle(Ink.muted)
                }
                if let followUp = FollowUpCenter.shared.item(for: row.followUpKey), followUp.matters {
                    Label(followUpHint(followUp), systemImage: followUp.askAgain >= 0.6 ? "arrow.uturn.backward" : "bubble.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Ink.spot)
                        .lineLimit(1)
                } else {
                    Text(row.chat.lastText).font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.chat.lastDate, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(Ink.muted)
                TrendBadge(trend: row.stats.trend)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Ink.surface))
        .overlay(alignment: .topTrailing) {
            if selected {
                Screentone(color: Ink.spot, spacing: 5, from: 0.9, to: 0, axis: .horizontal)
                    .frame(width: 90)
                    .clipShape(UnevenRoundedRectangle(topTrailingRadius: 12, style: .continuous))
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Ink.text : Ink.hairline, lineWidth: selected ? Ink.heavyLine : 1))
        .contentShape(Rectangle())
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
    static let chartSpot = Color(.sRGB, red: 1.0, green: 0.36, blue: 0.66)
    static let chartInkDark = Color(.sRGB, red: 0.93, green: 0.92, blue: 0.90)
    static let chartInkLight = Color(.sRGB, red: 0.08, green: 0.07, blue: 0.10)
    @State private var read: Card.PersonRead?
    @State private var readDate: Date?
    @State private var replies: Card.Replies?
    @State private var intent = ""
    @State private var working: String?
    @State private var error: String?
    @State private var consistency: Card.Consistency?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Avatar(name: row.chat.name, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.chat.name).font(Lettering.display(28, relativeTo: .title)).foregroundStyle(Ink.text)
                        Text("\(row.chat.source.displayName) · \(row.chat.messageCount) messages since \(row.chat.firstDate.formatted(.dateTime.month().year()))")
                            .font(.callout).foregroundStyle(Ink.muted)
                    }
                    Spacer()
                    MascotFace(mood: working != nil ? .thinking : (read.map { $0.closeness > 70 ? .love : .happy } ?? .idle), size: 54)
                }

                if row.stats.awaitingMyReply {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.badge.exclamationmark").font(.title2.weight(.bold)).foregroundStyle(Ink.text)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Waiting for your reply since \(row.stats.waitingSince ?? .now, format: .relative(presentation: .named))")
                                .font(.headline).foregroundStyle(Ink.text)
                            if let question = row.stats.lastQuestionFromThem {
                                Text("“\(question)”").italic().foregroundStyle(Ink.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(toned: true)
                }

                statsGrid
                activityChart

                if let read { PersonCard(card: read) }
                HStack {
                    Button {
                        Task { await runRead() }
                    } label: {
                        Label(read == nil ? "Read our story" : "Read again", systemImage: "sparkles")
                    }
                    .buttonStyle(.candy)
                    if let readDate {
                        Text("Read \(readDate, format: .relative(presentation: .named))").font(.caption).foregroundStyle(Ink.muted)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    PanelTitle(title: "Help me answer", symbol: "bubble.left.and.text.bubble.right")
                    CandyField(placeholder: "What do you want to say? (optional)", text: $intent, symbol: "pencil") {
                        Task { await suggest() }
                    }
                    Button {
                        Task { await suggest() }
                    } label: {
                        Label("Suggest replies", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.candy(.soft))
                }
                .panel()
                if let replies { RepliesCard(card: replies) }

                if let consistency { ConsistencyCard(card: consistency) }
                Button {
                    Task { await runConsistency() }
                } label: {
                    Label(consistency == nil ? "Face to face vs behind their back" : "Check again", systemImage: "theatermasks")
                }
                .buttonStyle(.candy(.soft))
                .help(Text("Compare how you talk to them with how you talk about them elsewhere"))

                if let working {
                    HStack { ProgressView().controlSize(.small); Text(working).foregroundStyle(Ink.muted) }
                }
                if let error { Text(error).foregroundStyle(Ink.peach) }
            }
            .padding(.bottom, 30)
            .frame(maxWidth: 820, alignment: .leading)
            // Start right after the list instead of floating in the middle.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .disabled(working != nil)
        .task {
            if let (card, date) = await RelationshipAnalyzer.cachedRead(row.chat) { read = card; readDate = date }
            consistency = await Consistency.cached(row.chat)
            if LaunchOptions.runRead { await runRead() }
        }
    }

    private var statsGrid: some View {
        let stats = row.stats
        return Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                Metric(symbol: "pencil.line", title: "You write", value: "\(Int(stats.balance * 100))%")
                Metric(symbol: "calendar", title: "Last 30 days", value: "\(stats.last30)")
                Metric(symbol: "hand.wave", title: "Who starts", value: "\(stats.myInitiations) : \(stats.theirInitiations)")
            }
            GridRow {
                Metric(symbol: "bolt", title: "You reply in", value: minutes(stats.myReplyMinutes))
                Metric(symbol: "tortoise", title: "They reply in", value: minutes(stats.theirReplyMinutes))
                Metric(symbol: mood(stats.theirSentiment), title: "Mood", value: moodWord(stats.theirSentiment))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var activityChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelTitle(title: "Messages per week", symbol: "chart.bar")
            Chart(Array(row.stats.weekly.enumerated()), id: \.offset) { index, count in
                BarMark(x: .value("Week", String(index)), y: .value("Messages", count), width: .ratio(0.62))
                    .foregroundStyle(index == row.stats.weekly.count - 1 ? Self.chartSpot : (scheme == .dark ? Self.chartInkDark : Self.chartInkLight))
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 90)
            .accessibilityLabel(Text("Messages per week, last 12 weeks"))
        }
        .panel()
    }

    private func minutes(_ value: Double?) -> String {
        guard let value else { return "—" }
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
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Ink.muted)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(Ink.text)
        }
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
