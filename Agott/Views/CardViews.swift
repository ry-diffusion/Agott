import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One reply from Agott: a speech balloon, then whatever panels it drew.
struct AssistantTurnView: View {
    var turn: Turn
    var compact = false
    var joinsAbove = false
    var joinsBelow = false
    /// A name in the reply that was clicked: their card opens beside it.
    @State private var peek: PersonPeek?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Before the first word: the live activity line, always. After
            // it: the folded "Thought for 6s" line, unless steps are hidden.
            let working = turn.isStreaming && turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && turn.cards.isEmpty && turn.error == nil
            // Compact (the overlay): its own header line is the progress,
            // so no second spinner and no steps here.
            if !compact, working || (AppSettings.shared.showSteps && !turn.steps.isEmpty) {
                StepsView(steps: turn.steps, isStreaming: working, started: turn.date,
                          status: working ? Agent.shared.status : nil)
            }
            // Cards come from tools, which run before the words that follow them.
            ForEach(turn.cards) { card in
                CardView(card: card)
                    .environment(\.inChat, true)
                    .environment(\.chatPanelStyle, .glass)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .topLeading).combined(with: .opacity), removal: .opacity))
            }
            // A reply can be only whitespace when a card already said it all.
            if !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if compact {
                    // Inline Markdown with people's tags turned into names.
                    Text(MarkdownView.inline(turn.text))
                        .textSelection(.enabled)
                        .foregroundStyle(Ink.text)
                } else {
                    // Agott's words straight on the page, in reading-size
                    // type: no bubble, no frame.
                    MarkdownView(text: turn.text, size: .zen)
                    // Names in the reply are links: clicking one shows who they are.
                    .environment(\.openURL, OpenURLAction { url in
                        guard let person = PersonPeek.from(url) else { return .systemAction }
                        peek = person
                        return .handled
                    })
                    .popover(item: $peek, arrowEdge: .leading) { PersonPeekCard(id: $0.id) }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(EntityText.plain(turn.text, hidden: AppSettings.shared.hideNames)) }
                        if !turn.isStreaming {
                            Button("Try again", systemImage: "arrow.clockwise") { Agent.shared.retry(turn.id) }
                        }
                    }
                }
            }
            if let error = turn.error {
                HStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                    if !compact {
                        Button {
                            withAnimation(Motion.settle) { Agent.shared.retry(turn.id) }
                        } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Ink.spot)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .quietSurface(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.settle, value: turn.cards.count)
    }

    /// A one-paragraph reply keeps its time on the last line; anything with
    /// structure gets the time under it.
    @ViewBuilder
    private var replyBody: some View {
        let blocks = MarkdownBlock.parse(turn.text)
        if blocks.count == 1, case .paragraph(let text) = blocks[0] {
            TextWithTime(text: MarkdownView.inline(text), time: turn.date, outgoing: false)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                MarkdownView(text: turn.text)
                if !turn.isStreaming {
                    Text(turn.date, format: .dateTime.hour().minute())
                        .font(.caption2).monospacedDigit().foregroundStyle(Ink.muted)
                }
            }
        }
    }

    /// Splits a reply into the short texts it was written as. Lists and
    /// numbered steps stay together with the line that introduces them.
    static func bubbles(_ text: String) -> [String] {
        let parts = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        func isListItem(_ line: Substring) -> Bool {
            let trimmed = line.drop(while: \.isWhitespace)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") { return true }
            let digits = trimmed.prefix(while: \.isNumber)
            return !digits.isEmpty && trimmed.dropFirst(digits.count).hasPrefix(".")
        }
        var merged: [String] = []
        for part in parts {
            let lastLine = merged.last?.split(separator: "\n").last ?? ""
            if isListItem(Substring(part)), let last = merged.last, last.hasSuffix(":") || isListItem(lastLine) {
                merged[merged.count - 1] = last + "\n" + part
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}

/// Agott at work: a few drops of ink that drift, merge and part again.
///
/// Messengers show three dots; here they are liquid. Each drop follows its
/// own slow loop, and a blur with an alpha threshold makes drops that come
/// close melt into one shape (the "gooey" effect), so it reads as something
/// alive thinking rather than a progress bar. Pink fades into violet across
/// the drops. Still for reduced motion.
struct TypingDots: View {
    static let lilac = Color(.sRGB, red: 0.68, green: 0.52, blue: 1.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            LinearGradient(colors: [Ink.muted, Ink.text.opacity(0.5), Ink.muted],
                           startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t * 0.6), y: 0),
                           endPoint: UnitPoint(x: 0.5 - 0.5 * cos(t * 0.6), y: 1))
                .mask { Self.drops(at: t) }
                .frame(width: 58, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Ink.bubble))
        .accessibilityLabel(Text("Agott is typing"))
    }

    private static func drops(at t: Double) -> some View {
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.45, color: .white))
            context.addFilter(.blur(radius: 3.5))
            context.drawLayer { layer in
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0..<4 {
                    let i = Double(index)
                    // Slow, out-of-step loops: never the same picture twice.
                    let x = mid.x + size.width * 0.36 * sin(t * (0.9 + i * 0.23) + i * 1.7)
                    let y = mid.y + size.height * 0.16 * cos(t * (1.3 + i * 0.17) + i * 2.3)
                    let r = 4.0 + 1.3 * sin(t * 1.7 + i * 2.0)
                    layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white))
                }
            }
        }
    }
}

struct CardView: View {
    var card: Card

    var body: some View {
        switch card {
        case .explanation(let explanation): ExplanationCard(card: explanation)
        case .replies(let replies): RepliesCard(card: replies)
        case .checklist(let checklist): ChecklistCard(card: checklist)
        case .person(let person): PersonCard(card: person)
        case .events(let events): EventsCard(card: events)
        case .note(let note): NoteCard(card: note)
        case .approval(let approval): ApprovalCard(card: approval)
        case .consistency(let consistency): ConsistencyCard(card: consistency)
        case .artifact(let artifact): ArtifactCard(artifact: artifact)
        case .chart(let chart): ChartCardView(chart: chart)
        case .collection(let collection): CollectionCardView(card: collection)
        }
    }
}

/// Copies text, and on the Mac can also put it straight into the app you
/// were using.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    static func insertIntoTargetApp(_ text: String) {
        #if os(macOS)
        Task {
            await ComputerControl.focusTarget()
            try? TextInsertion.insert(text)
        }
        #else
        copy(text)
        #endif
    }
}

struct ExplanationCard: View {
    var card: Card.Explanation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb.max").font(.title3.weight(.bold))
                Text(EntityText.plain(card.term, hidden: AppSettings.shared.hideNames)).font(.title3.weight(.bold))
            }
            .foregroundStyle(Ink.text)
            TaggedText(text: card.meaning).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(card.examples.enumerated()), id: \.offset) { _, example in
                    HStack(alignment: .top, spacing: 10) {
                        Text(example.text)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Ink.text)
                            .balloon(.leading, fill: Ink.raised, padding: EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                        Text(example.note)
                            .font(.caption)
                            .foregroundStyle(Ink.muted)
                            .padding(.top, 8)
                    }
                }
            }
            if let tip = card.tip, !tip.isEmpty {
                Label(tip, systemImage: "hand.point.right")
                    .font(.callout)
                    .foregroundStyle(Ink.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(toned: true)
    }
}

/// Text the model wrote for a card: people's tags become their names
/// (chips with their card), as in the reply itself, never "<e id=243/>".
struct TaggedText: View {
    var text: String

    var body: some View {
        if MarkdownView.mentionsPeople(text) {
            MentionParagraph(text: text)
        } else {
            Text(text)
        }
    }
}

struct RepliesCard: View {
    var card: Card.Replies
    @State private var used: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "You could reply", symbol: "bubble.left.and.text.bubble.right")
            // The model names people by tag: here they become names (chips
            // where there is room), never "<e id=243/>".
            TaggedText(text: card.context).font(.callout).foregroundStyle(Ink.muted)
            ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                // What gets typed or copied is sent to someone: real names.
                let reply = EntityText.plain(option.text, hidden: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Chip(text: option.tone.capitalized, spot: index == 0)
                        Text(EntityText.plain(option.why, hidden: AppSettings.shared.hideNames))
                            .font(.caption).foregroundStyle(Ink.muted).lineLimit(2)
                    }
                    Text(EntityText.plain(option.text, hidden: AppSettings.shared.hideNames))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        #if os(macOS)
                        Button {
                            used = index
                            Clipboard.insertIntoTargetApp(reply)
                        } label: {
                            Label(used == index ? "Inserted" : "Insert", systemImage: used == index ? "checkmark" : "text.insert")
                        }
                        .buttonStyle(.candy(.primary, compact: true))
                        #endif
                        Button {
                            Clipboard.copy(reply)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.candy(.soft, compact: true))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.raised))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct ChecklistCard: View {
    var card: Card.Checklist
    @State private var done: Set<Int> = []
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelTitle(title: LocalizedStringKey(card.title), symbol: "checklist")
            ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                Button {
                    if done.contains(index) { done.remove(index) } else { done.insert(index) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done.contains(index) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done.contains(index) ? Ink.spot : Ink.text)
                        Text(item)
                            .strikethrough(done.contains(index))
                            .foregroundStyle(done.contains(index) ? Ink.muted : Ink.text)
                    }
                }
                .buttonStyle(.plain)
            }
            Button {
                for item in card.items { _ = try? Organizer.shared.createReminder(title: item, due: nil, notes: card.title) }
                added = true
            } label: {
                Label(added ? "Added to Reminders" : "Add to Reminders", systemImage: added ? "checkmark" : "plus")
            }
            .buttonStyle(.candy(.soft, compact: true))
            .disabled(added)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct PersonCard: View {
    var card: Card.PersonRead

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Avatar(name: card.name, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(EntityText.plain(card.name, hidden: AppSettings.shared.hideNames)).font(.headline).foregroundStyle(Ink.text)
                    Text(card.vibe.capitalized).font(.callout).foregroundStyle(Ink.muted)
                }
                Spacer()
                ClosenessRing(value: card.closeness)
            }
            TaggedText(text: card.summary).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            if !card.openLoops.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Left hanging").font(.callout.weight(.bold)).foregroundStyle(Ink.text)
                    ForEach(card.openLoops, id: \.self) {
                        Label($0, systemImage: "arrow.uturn.backward").font(.callout).foregroundStyle(Ink.text)
                    }
                }
            }
            if !card.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ideas").font(.callout.weight(.bold)).foregroundStyle(Ink.text)
                    ForEach(card.suggestions, id: \.self) {
                        Label($0, systemImage: "sparkle").font(.callout).foregroundStyle(Ink.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(toned: true)
    }
}

/// Closeness as a number, lettered. It is the content, so it is shown, not
/// drawn as a dial.
struct ClosenessRing: View {
    var value: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value, format: .number).font(Lettering.display(28, relativeTo: .title)).foregroundStyle(Ink.text)
                Text(verbatim: "/100").font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
            }
            Text("closeness").font(.caption2.weight(.semibold)).foregroundStyle(Ink.muted)
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Closeness \(value) of 100"))
    }
}

/// Initials, lettered on toned paper.
struct Avatar: View {
    var name: String
    var size: CGFloat = 32

    /// Telegram's avatar for someone without a photo, everywhere in the app.
    var body: some View {
        InitialsAvatar(text: name.isEmpty ? "?" : name, size: size)
    }
}

struct EventsCard: View {
    var card: Card.EventList
    @State private var expanded = false
    /// Enough to see the next day or two at a glance; the rest on request.
    static let collapsedLimit = 8

    /// Events by day, in order, each day once.
    private var days: [(day: Date, items: [Card.EventList.Item])] {
        let calendar = Calendar.current
        let shown = expanded ? card.items : Array(card.items.prefix(Self.collapsedLimit))
        var result: [(day: Date, items: [Card.EventList.Item])] = []
        for item in shown {
            let day = calendar.startOfDay(for: item.start)
            if let last = result.indices.last, result[last].day == day {
                result[last].items.append(item)
            } else {
                result.append((day, [item]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Calendar", symbol: "calendar")
            ForEach(days, id: \.day) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(Self.dayName(group.day))
                        .font(Lettering.display(12, relativeTo: .caption))
                        .foregroundStyle(Calendar.current.isDateInToday(group.day) ? Ink.spot : Ink.text)
                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.start, format: .dateTime.hour().minute())
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(Ink.muted)
                                .frame(width: 40, alignment: .leading)
                            Text(EntityText.plain(item.title, hidden: AppSettings.shared.hideNames))
                                .font(.callout)
                                .foregroundStyle(Ink.text)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if !item.detail.isEmpty {
                                Text(EntityText.plain(item.detail, hidden: AppSettings.shared.hideNames))
                                    .font(.caption)
                                    .foregroundStyle(Ink.muted)
                                    .lineLimit(1)
                            }
                        }
                        .help(Text(item.detail.isEmpty ? item.title : "\(item.title) · \(item.detail)"))
                    }
                }
            }
            if card.items.count > Self.collapsedLimit {
                Button {
                    withAnimation(Motion.settle) { expanded.toggle() }
                } label: {
                    Text(expanded ? String(localized: "Show less")
                                  : String(localized: "Show \(card.items.count - Self.collapsedLimit) more"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Ink.spot)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// "Today", "Tomorrow", or the weekday and date.
    static func dayName(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

struct NoteCard: View {
    var card: Card.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(title: LocalizedStringKey(card.title), symbol: card.symbol)
            TaggedText(text: card.body).foregroundStyle(Ink.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct ApprovalCard: View {
    var card: Card.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(
                title: LocalizedStringKey(card.title),
                symbol: card.state == .pending ? "hand.raised" : card.state == .approved ? "checkmark.circle" : "xmark.circle")
            let parts = card.detail.components(separatedBy: "\n\n")
            Text(parts.first ?? "").font(.callout).foregroundStyle(Ink.text)
            if parts.count > 1 {
                ScrollView {
                    Text(parts.dropFirst().joined(separator: "\n\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised))
            }
            switch card.state {
            case .pending:
                HStack(spacing: 8) {
                    Button { Approvals.shared.answer(card.id, allow: true) } label: { Text("Allow") }
                        .buttonStyle(.candy(.primary, compact: true))
                        .keyboardShortcut(.defaultAction)
                    Button("Don't") { Approvals.shared.answer(card.id, allow: false) }
                        .buttonStyle(.candy(.soft, compact: true))
                }
            case .approved:
                Text("Allowed").font(.caption.weight(.semibold)).foregroundStyle(Ink.muted)
            case .denied:
                Text("Declined").font(.caption.weight(.semibold)).foregroundStyle(Ink.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14, toned: card.state == .pending)
    }
}

/// Face to face versus behind their back: two tones side by side, the gap
/// between them, and the quotes that show it.
struct ConsistencyCard: View {
    var card: Card.Consistency

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                PanelTitle(title: "Face to face vs behind their back", symbol: "theatermasks")
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(card.gap, format: .number).font(Lettering.display(26, relativeTo: .title))
                    Text(verbatim: "/100").font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
                }
                .foregroundStyle(card.gap >= 50 ? Ink.spot : Ink.text)
                .accessibilityLabel(Text("Gap \(card.gap) of 100"))
            }
            TaggedText(text: card.verdict).font(.body.weight(.semibold)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                let name = EntityText.plain(card.name, hidden: AppSettings.shared.hideNames)
                side(title: "To \(name)", symbol: "person.fill.checkmark", text: card.toThem, tone: card.toneToThem)
                side(title: "About \(name)", symbol: "bubble.left.and.exclamationmark.bubble.right", text: card.aboutThem, tone: card.toneAboutThem)
            }

            if !card.quotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(card.quotes.enumerated()), id: \.offset) { _, quote in
                        VStack(alignment: quote.direct ? .leading : .trailing, spacing: 3) {
                            Text(EntityText.plain(quote.text, hidden: AppSettings.shared.hideNames))
                                .font(.callout)
                                .foregroundStyle(quote.direct ? Ink.text : Ink.onSpot)
                                .balloon(quote.direct ? .leading : .trailing, fill: quote.direct ? Ink.raised : Ink.spot,
                                         padding: EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                            TaggedText(text: quote.context).font(.caption2).foregroundStyle(Ink.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: quote.direct ? .leading : .trailing)
                    }
                }
            }

            if !card.othersAboutThem.isEmpty {
                Label(card.othersAboutThem, systemImage: "person.3").font(.callout).foregroundStyle(Ink.text)
            }
            Label(card.advice, systemImage: "hand.point.right").font(.callout).foregroundStyle(Ink.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(toned: card.gap >= 50)
    }

    private func side(title: LocalizedStringKey, symbol: String, text: String, tone: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
            TaggedText(text: text).font(.callout).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            ToneBar(value: tone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.raised))
    }
}

/// Tone from -1 to 1 as a marker on a plain track: cold left, warm right.
struct ToneBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width * CGFloat((max(-1, min(1, value)) + 1) / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.text.opacity(0.1)).frame(height: 4)
                Capsule().fill(Ink.spot.opacity(0.7)).frame(width: max(4, x), height: 4)
                Circle().fill(Ink.text).frame(width: 10, height: 10).offset(x: x - 5)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel(Text("Tone"))
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(2))))
    }
}
