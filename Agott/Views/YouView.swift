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
