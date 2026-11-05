import SwiftUI

/// A settings row that opens the model browser.
struct ModelPickerRow: View {
    var title: LocalizedStringKey
    @Binding var provider: ModelProvider
    @Binding var model: String
    /// Offer "Same as chat model" (an empty model on OpenCode).
    var allowsSame: Bool
    @State private var open = false
    @State private var catalog = ModelCatalog.shared

    var body: some View {
        LabeledContent(title) {
            Button {
                open = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: provider == .onDevice ? "laptopcomputer" : provider == .privateCloud ? "lock.icloud" : "cloud")
                    Text(label).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.candy(.soft, compact: true))
        }
        .sheet(isPresented: $open) {
            ModelPicker(provider: $provider, model: $model, allowsSame: allowsSame)
        }
    }

    private var label: String {
        switch provider {
        case .onDevice, .privateCloud: return provider.title
        case .openCode:
            if model.isEmpty { return String(localized: "Same as chat model") }
            return catalog.model(model)?.name ?? model
        }
    }
}

/// Every OpenCode Go model, searchable. Picking one sets its endpoint and,
/// for analysis, the context window batches are sized to.
struct ModelPicker: View {
    @Binding var provider: ModelProvider
    @Binding var model: String
    var allowsSame: Bool
    @State private var catalog = ModelCatalog.shared
    @State private var settings = AppSettings.shared
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [CatalogModel] {
        guard !query.isEmpty else { return catalog.models }
        let q = query.folded
        return catalog.models.filter {
            $0.name.folded.contains(q) || $0.id.folded.contains(q) || $0.family.folded.contains(q) || $0.summary.folded.contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Choose a model").font(Lettering.display(22, relativeTo: .title2)).foregroundStyle(Ink.text)
                Spacer()
                if catalog.isLoading { ProgressView().controlSize(.small) }
                CandyIconButton(symbol: "arrow.clockwise") { Task { await catalog.refresh() } }
                    .help(Text("Refresh"))
                CandyIconButton(symbol: "xmark") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            CandyField(placeholder: "Search models: name, family, what it's good at…", text: $query, symbol: "magnifyingglass")
            if let error = catalog.error, catalog.models.isEmpty {
                Text(error).font(.callout).foregroundStyle(Ink.muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if query.isEmpty {
                        Text("Apple").font(.caption.weight(.bold)).foregroundStyle(Ink.muted).padding(.top, 4)
                        appleRow(.onDevice, symbol: "laptopcomputer")
                        appleRow(.privateCloud, symbol: "lock.icloud")
                        Text(verbatim: "OpenCode Go").font(.caption.weight(.bold)).foregroundStyle(Ink.muted).padding(.top, 8)
                        if !settings.hasAPIKey {
                            Text("Add your OpenCode Go API key in Settings to use these.").font(.caption).foregroundStyle(Ink.muted)
                        }
                        if allowsSame {
                            row(id: "", name: String(localized: "Same as chat model"), detail: String(localized: "Use the chat model for this too."), model: nil)
                        }
                    }
                    ForEach(filtered) { model in
                        row(id: model.id, name: model.name, detail: model.summary, model: model)
                    }
                }
            }
            .scrollIndicators(.never)
            Text("Gemini uses Google's API, which Agott doesn't speak yet; every other model works.")
                .font(.caption).foregroundStyle(Ink.muted)
        }
        .padding(22)
        .frame(width: 620, height: 640)
        .background(Ink.canvas)
        .task { await catalog.refresh() }
    }

    /// Apple's models, chosen as models in their own right.
    private func appleRow(_ option: ModelProvider, symbol: String) -> some View {
        let selected = provider == option
        let available = ModelHub.isAvailable(option)
        return Button {
            provider = option
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Ink.spot : Ink.muted).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Label(option.title, systemImage: symbol).font(.body.weight(.semibold)).foregroundStyle(Ink.text)
                    Text(option.detail).font(.caption).foregroundStyle(Ink.muted).lineLimit(2)
                    HStack(spacing: 6) {
                        Chip(text: option == .onDevice ? String(localized: "Free · private") : String(localized: "Private"), symbol: "lock")
                        if !available { Chip(text: String(localized: "Not available on this Mac"), symbol: "exclamationmark.triangle") }
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Ink.raised : Ink.surface))
            .opacity(available ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(id: String, name: String, detail: String, model: CatalogModel?) -> some View {
        let selected = provider == .openCode && self.model == id
        let usable = model?.isSupported ?? true
        return Button {
            guard usable else { return }
            provider = .openCode
            self.model = id
            if let model {
                // The analysis window follows the model, within reason.
                settings.contextTokens = min(model.context, 256_000)
            }
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Ink.spot : Ink.muted)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name).font(.body.weight(.semibold)).foregroundStyle(Ink.text)
                        if !id.isEmpty { Text(id).font(.caption).foregroundStyle(Ink.muted) }
                    }
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Ink.muted).lineLimit(2)
                    }
                    if let model {
                        HStack(spacing: 6) {
                            Chip(text: Self.tokens(model.context), symbol: "text.alignleft")
                            if model.reasoning { Chip(text: String(localized: "Reasoning"), symbol: "brain") }
                            if model.vision { Chip(text: String(localized: "Sees images"), symbol: "eye") }
                            if let input = model.priceIn, let output = model.priceOut {
                                Chip(text: String(format: "$%.2f / $%.2f", input, output), symbol: "dollarsign")
                                    .help(Text("Price per million tokens, in / out"))
                            }
                            if !usable { Chip(text: String(localized: "Needs another API"), symbol: "lock") }
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Ink.raised : Ink.surface))
            .opacity(usable ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
    }

    static func tokens(_ count: Int) -> String {
        count >= 1_000_000
            ? String(localized: "\(count / 1_000_000)M context")
            : String(localized: "\(count / 1_000)k context")
    }
}
