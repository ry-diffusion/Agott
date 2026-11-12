import SwiftUI

/// Dreams on the Memory page: when memory last went over itself, what it
/// changed, the pairs it could not settle alone, and a button to dream now.
struct DreamsCard: View {
    @State private var dreams = Dreams.shared
    @State private var settings = AppSettings.shared
    @State private var directory = PeopleDirectory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "Dreams")
            SettingsCard {
                SettingsRow(symbol: "moon.stars", title: "Memory goes over itself", verbatim: status) {
                    if dreams.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Dream now") { Task { await dreams.run() } }
                            .buttonStyle(.candy(.soft, compact: true))
                    }
                }
                if let last = dreams.last, !dreams.isRunning {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(last.lines, id: \.self) { line in
                            Label(line, systemImage: "checkmark")
                                .font(.callout)
                                .foregroundStyle(Ink.text)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(dreams.maybes) { pair in
                    SettingsRow(symbol: "person.2", title: "Are these the same person?", verbatim: names(pair)) {
                        HStack(spacing: 6) {
                            Button("Same") { Task { await dreams.settle(pair, same: true) } }
                                .buttonStyle(.candy(.soft, compact: true))
                            Button("Different") { Task { await dreams.settle(pair, same: false) } }
                                .buttonStyle(.candy(.soft, compact: true))
                        }
                    }
                }
                SettingsRow(symbol: "clock.arrow.circlepath", title: "Dream by itself",
                            detail: "Once a day, after memory updates") {
                    Toggle("", isOn: $settings.dreams).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .task { await dreams.load() }
    }

    private var status: String {
        if dreams.isRunning { return dreams.note ?? String(localized: "Dreaming…") }
        guard let last = dreams.last else {
            return String(localized: "Gives people their right names, joins entries that are one person, checks whose nickname is whose, and marks what is over as over.")
        }
        return String(localized: "Last dream \(last.date.formatted(.relative(presentation: .named)))")
    }

    private func names(_ pair: MemoryStore.Pair) -> String {
        directory.label(pair.a.id, hidden: settings.hideNames) + " · " + directory.label(pair.b.id, hidden: settings.hideNames)
    }
}
