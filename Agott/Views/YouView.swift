import SwiftUI

/// What Agott believes about you, editable, with the button that makes it
/// learn more.
struct YouView: View {
    @State private var settings = AppSettings.shared
    @State private var indexer = Indexer.shared
    @State private var facts: [MemoryFact] = []
    @State private var filter = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "You", subtitle: "Agott starts every conversation from this. Edit anything that's wrong.", symbol: "person") {
                    MuseFace(mood: indexer.isLearning ? .thinking : .love, size: 54)
                }
                PanelTitle(title: "About you", symbol: "text.quote")

                TextEditor(text: $settings.aboutMe)
                    .font(.body)
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .foregroundStyle(Ink.text)
                    .panel(padding: 8)
                    .overlay(alignment: .topLeading) {
                        if settings.aboutMe.isEmpty {
                            Text("Nothing yet. Let Agott read your Claude history and messages, or write about yourself here.")
                                .foregroundStyle(Ink.muted).padding(14).allowsHitTesting(false)
                        }
                    }

                HStack {
                    if indexer.isLearning {
                        ProgressView().controlSize(.small)
                        if case .learning(let done, let total) = indexer.phase {
                            Text("Reading moment \(done) of \(total)…").foregroundStyle(Ink.muted)
                        }
                        Button("Stop") { indexer.stopLearning() }.buttonStyle(.candy(.soft, compact: true))
                    } else {
                        Button {
                            indexer.learn()
                        } label: {
                            Label("Learn more about me", systemImage: "sparkles")
                        }
                        .buttonStyle(.candy)
                        Text("Reads up to 400 moments you wrote, packed into batches that fit the model's context.")
                            .font(.caption).foregroundStyle(Ink.muted)
                    }
                }

                #if os(macOS)
                MusicMoodSection()
                #endif

                HStack {
                    PanelTitle(title: "What Agott knows", symbol: "pin")
                    Spacer()
                    CandyField(placeholder: "Filter", text: $filter, symbol: "line.3.horizontal.decrease").frame(maxWidth: 220)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10)], spacing: 10) {
                ForEach(facts.filter { filter.isEmpty || $0.sentence.folded.contains(filter.folded) }) { fact in
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: fact.source.symbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Ink.text)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Text(fact.subject).bold()) \(fact.predicate) \(Text(fact.object).foregroundStyle(Ink.spot).bold())")
                                .foregroundStyle(Ink.text)
                            Text("\(Int(fact.confidence * 100))% · \(fact.date.formatted(.dateTime.day().month().year()))")
                                .font(.caption2).foregroundStyle(Ink.muted)
                        }
                        Spacer()
                        Button {
                            Task {
                                try? await MemoryStore.shared.deleteFact(id: fact.id)
                                await reload()
                            }
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.muted) }
                        .buttonStyle(.plain)
                        .help(Text("Forget this"))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
                }
                }
                if facts.isEmpty {
                    Text("No facts yet.").foregroundStyle(Ink.muted)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 30)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .task { await reload() }
        .onChange(of: indexer.isLearning) { _, learning in
            if !learning { Task { await reload() } }
        }
    }

    private func reload() async {
        facts = (try? await MemoryStore.shared.facts(limit: 400)) ?? []
    }
}

#if os(macOS)
/// What you have been listening to, and how it felt.
private struct MusicMoodSection: View {
    @State private var listener = MusicListener.shared
    @State private var settings = AppSettings.shared
    @State private var summary: MusicMood.Summary?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(title: "Music and mood", symbol: "music.note")
            if !settings.listenToMusic {
                HStack {
                    Text("Agott isn't noticing your music.").foregroundStyle(Ink.muted)
                    Button("Turn on") { settings.listenToMusic = true; listener.start() }
                        .buttonStyle(.candy(.soft, compact: true))
                }
            } else {
                if let play = listener.nowPlaying {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").font(.title3.weight(.bold)).foregroundStyle(Ink.spot)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(play.track).font(.headline).foregroundStyle(Ink.text).lineLimit(1)
                            Text("\(play.artist) · \(play.app)").font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                        }
                        Spacer()
                        if let mood = listener.nowMood {
                            Chip(text: mood.mood.capitalized, symbol: "heart", spot: true)
                        }
                    }
                    .panel(padding: 12)
                }
                if let summary, summary.plays > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last two weeks · \(summary.plays) songs").font(.caption.weight(.bold)).foregroundStyle(Ink.muted)
                        let total = max(1, summary.moods.map(\.1).reduce(0, +))
                        ForEach(summary.moods.prefix(5), id: \.0) { mood, count in
                            HStack(spacing: 10) {
                                Text(mood.capitalized).font(.callout).foregroundStyle(Ink.text).frame(width: 96, alignment: .leading)
                                GeometryReader { proxy in
                                    Capsule().fill(Ink.spot)
                                        .frame(width: max(6, proxy.size.width * CGFloat(count) / CGFloat(total)))
                                }
                                .frame(height: 8)
                                Text("\(Int(Double(count) / Double(total) * 100))%").font(.caption).monospacedDigit()
                                    .foregroundStyle(Ink.muted).frame(width: 40, alignment: .trailing)
                            }
                        }
                        if let best = summary.toneByMood.first, let worst = summary.toneByMood.last, summary.toneByMood.count > 1 {
                            Label("Your messages are warmest with \(best.0) music and coolest with \(worst.0).", systemImage: "text.bubble")
                                .font(.callout).foregroundStyle(Ink.text)
                        }
                        if !summary.topArtists.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(summary.topArtists, id: \.0) { Chip(text: "\($0.0) · \($0.1)", symbol: "music.mic") }
                            }
                        }
                    }
                    .panel(padding: 14)
                } else {
                    Text("Play something on Spotify or Apple Music and Agott will start to notice how your music feels.")
                        .font(.callout).foregroundStyle(Ink.muted)
                }
            }
        }
        .task(id: listener.nowPlaying?.track) { summary = await MusicMood.summary(days: 14) }
    }
}
#endif
