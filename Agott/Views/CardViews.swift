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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepsView(steps: turn.steps, isStreaming: turn.isStreaming)
            if !turn.text.isEmpty {
                if compact {
                    Text(Self.markdown(turn.text))
                        .textSelection(.enabled)
                        .foregroundStyle(Ink.text)
                } else {
                    // Agott texts in short bursts; each paragraph is a bubble.
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(Self.bubbles(turn.text).enumerated()), id: \.offset) { index, part in
                            Text(Self.markdown(part))
                                .textSelection(.enabled)
                                .foregroundStyle(Ink.text)
                                .balloon(index == 0 ? .leading : .none)
                                .padding(.leading, index == 0 ? 0 : 10)
                        }
                    }
                }
            } else if turn.isStreaming && turn.cards.isEmpty && turn.steps.isEmpty {
                TypingDots().balloon(.leading)
            }
            ForEach(turn.cards) { card in
                CardView(card: card)
                    .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .topLeading).combined(with: .opacity), removal: .opacity))
            }
            if let error = turn.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Ink.text)
                    .textSelection(.enabled)
                    .panel(padding: 12, toned: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.settle, value: turn.cards.count)
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
        return merged.isEmpty ? [text] : merged
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(0.25 + 0.75 * max(0, sin(t * 5 - Double(index) * 0.8)))
                }
            }
            .foregroundStyle(Ink.text)
        }
        .accessibilityLabel(Text("Thinking"))
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
                Text(card.term).font(Lettering.display(22, relativeTo: .title2))
            }
            .foregroundStyle(Ink.text)
            Text(card.meaning).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
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

struct RepliesCard: View {
    var card: Card.Replies
    @State private var used: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "You could reply", symbol: "bubble.left.and.text.bubble.right")
            Text(card.context).font(.callout).foregroundStyle(Ink.muted)
            ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Chip(text: option.tone.capitalized, spot: index == 0)
                        Text(option.why).font(.caption).foregroundStyle(Ink.muted).lineLimit(2)
                    }
                    Text(option.text)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Ink.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        #if os(macOS)
                        Button {
                            used = index
                            Clipboard.insertIntoTargetApp(option.text)
                        } label: {
                            Label(used == index ? "Inserted" : "Insert", systemImage: used == index ? "checkmark" : "text.insert")
                        }
                        .buttonStyle(.candy(.primary, compact: true))
                        #endif
                        Button {
                            Clipboard.copy(option.text)
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
                    Text(card.name).font(Lettering.display(19, relativeTo: .title3)).foregroundStyle(Ink.text)
                    Text(card.vibe.capitalized).font(.callout).foregroundStyle(Ink.muted)
                }
                Spacer()
                ClosenessRing(value: card.closeness)
            }
            Text(card.summary).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Text(initials.isEmpty ? "?" : initials.uppercased())
            .font(Lettering.display(size * 0.36))
            .foregroundStyle(Ink.text)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(Ink.surface)
                    Screentone(color: Ink.text.opacity(0.28), spacing: 4.5, from: 0, to: 0.8)
                        .clipShape(Circle())
                }
            }
    }
}

struct EventsCard: View {
    var card: Card.EventList

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(title: "Calendar", symbol: "calendar")
            ForEach(Array(card.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(item.start, format: .dateTime.weekday(.abbreviated).day())
                            .font(.callout.weight(.bold)).foregroundStyle(Ink.text)
                        Text(item.start, format: .dateTime.hour().minute())
                            .font(.caption).foregroundStyle(Ink.muted)
                    }
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(Ink.text)
                        if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(Ink.muted) }
                    }
                }
                if index < card.items.count - 1 {
                    Rectangle().fill(Ink.hairline).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

struct NoteCard: View {
    var card: Card.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(title: LocalizedStringKey(card.title), symbol: card.symbol)
            Text(card.body).foregroundStyle(Ink.text)
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
            Text(card.verdict).font(.body.weight(.semibold)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                side(title: "To \(card.name)", symbol: "person.fill.checkmark", text: card.toThem, tone: card.toneToThem)
                side(title: "About \(card.name)", symbol: "bubble.left.and.exclamationmark.bubble.right", text: card.aboutThem, tone: card.toneAboutThem)
            }

            if !card.quotes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(card.quotes.enumerated()), id: \.offset) { _, quote in
                        VStack(alignment: quote.direct ? .leading : .trailing, spacing: 3) {
                            Text(quote.text)
                                .font(.callout)
                                .foregroundStyle(quote.direct ? Ink.text : Ink.onSpot)
                                .balloon(quote.direct ? .leading : .trailing, fill: quote.direct ? Ink.raised : Ink.spot,
                                         padding: EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                            Text(quote.context).font(.caption2).foregroundStyle(Ink.muted)
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
            Text(text).font(.callout).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
            ToneBar(value: tone)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.raised))
    }
}

/// Tone from -1 to 1 as a marker on a screentone track: cold left, warm right.
struct ToneBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            let x = proxy.size.width * CGFloat((max(-1, min(1, value)) + 1) / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.text.opacity(0.08))
                Screentone(color: Ink.spot, spacing: 4, from: 0, to: 0.9, axis: .horizontal)
                    .clipShape(Capsule())
                    .opacity(0.8)
                Circle().fill(Ink.text).frame(width: 10, height: 10).offset(x: x - 5)
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel(Text("Tone"))
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(2))))
    }
}
