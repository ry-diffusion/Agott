#if os(macOS)
import SwiftUI

/// The sidebar, a notebook's: the window buttons with hide and search
/// beside them, the screens, your recent conversations, and at the foot
/// Settings, memory at work and you.
struct Sidebar: View {
    static let width: CGFloat = 248

    @State private var navigator = Navigator.shared
    @State private var agent = Agent.shared
    @State private var settings = AppSettings.shared
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The close, minimise and zoom buttons sit on the left of this row.
            HStack(spacing: 2) {
                Spacer().frame(width: WindowBar.afterButtons)
                Button { withAnimation(.easeInOut(duration: 0.3)) { navigator.zen = true } } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(HoverIconStyle(size: 28))
                .tip("Hide the sidebar (⌃⌘S)", edge: .bottom)
                Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(HoverIconStyle(size: 28))
                    .keyboardShortcut("k", modifiers: .command)
                    .tip("Search conversations (⌘K)", edge: .bottom)
                    .popover(isPresented: $searching, arrowEdge: .bottom) {
                        ConversationSearch { searching = false }
                    }
                Spacer()
            }
            .font(.system(size: 14, weight: .regular))
            .frame(height: WindowBar.height)
            .titleBar()
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(AppSection.allCases) { item in
                        SidebarRow(title: Text(item.title), symbol: item.symbol, selected: navigator.section == item) {
                            navigator.section = item
                        }
                    }

                    if !agent.conversations.isEmpty {
                        Text("Recent")
                            .font(.subheadline)
                            .foregroundStyle(Ink.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 22)
                            .padding(.bottom, 6)
                        ForEach(agent.conversations.prefix(8)) { item in
                            SidebarRow(title: Text(EntityText.plain(item.displayTitle, hidden: settings.hideNames)),
                                       symbol: nil,
                                       selected: navigator.section == .chat && item.id == agent.currentID,
                                       live: agent.isBusy && agent.runningConversation == item.id) {
                                navigator.section = .chat
                                withAnimation(Motion.settle) { agent.open(item.id) }
                            }
                            .contextMenu {
                                Button("Delete conversation", systemImage: "trash", role: .destructive) {
                                    withAnimation(Motion.settle) { agent.delete(item.id) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            HStack(spacing: 2) {
                Button { navigator.settingsPage = .preferences } label: { Image(systemName: "gearshape") }
                    .buttonStyle(HoverIconStyle(size: 28))
                    .tip("Settings", edge: .top)
                Button { settings.hideNames.toggle() } label: {
                    Image(systemName: settings.hideNames ? "eye.slash" : "eye")
                        .foregroundStyle(settings.hideNames ? Ink.spot : Ink.muted)
                }
                .buttonStyle(HoverIconStyle(size: 28))
                .tip(settings.hideNames ? "Show names" : "Hide names of people and groups", edge: .top)
                ActivityButton { navigator.section = .memory }
                Spacer()
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Rectangle().fill(Ink.hairline).frame(height: 1)

            Button { navigator.section = .you } label: {
                HStack(spacing: 10) {
                    InitialsAvatar(text: settings.myName.isEmpty ? "?" : settings.myName, size: 26)
                    Text(settings.myName.isEmpty ? String(localized: "You") : settings.myName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Ink.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 8, inset: 0)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background { SidebarMaterial().ignoresSafeArea() }
    }
}

/// One line of the sidebar: a screen with its symbol, or a conversation.
private struct SidebarRow: View {
    var title: Text
    var symbol: String?
    var selected: Bool
    var live = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .frame(width: 18)
                        .foregroundStyle(selected ? Ink.text : Ink.muted)
                }
                title
                    .font(.system(size: 13.5))
                    .foregroundStyle(selected || symbol != nil ? Ink.text : Ink.text.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if live {
                    // Agott is working in this conversation: a spinner, like a tab loading.
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Ink.spot)
                        .accessibilityLabel(Text("Working"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Ink.text.opacity(selected ? 0.09 : hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Every conversation, searched by title, what it ended on and who it is about.
struct ConversationSearch: View {
    var done: () -> Void
    @State private var agent = Agent.shared
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [ConversationInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(agent.conversations.prefix(12)) }
        return agent.conversations.filter {
            $0.displayTitle.localizedStandardContains(q) || $0.preview.localizedStandardContains(q)
                || ($0.people ?? []).contains { $0.localizedStandardContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = results.first { open(first) } }
            }
            .padding(10)
            .quietSurface(RoundedRectangle(cornerRadius: 10, style: .continuous), fill: Ink.raised)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { item in
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(EntityText.plain(item.displayTitle, hidden: AppSettings.shared.hideNames))
                                    .font(.callout).foregroundStyle(Ink.text).lineLimit(1)
                                Text(EntityText.plain(item.preview.markdownStripped, hidden: AppSettings.shared.hideNames))
                                    .font(.caption).foregroundStyle(Ink.muted).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 8, inset: 0)
                    }
                    if results.isEmpty {
                        Text("No conversations match").font(.callout).foregroundStyle(Ink.muted).padding(8)
                    }
                }
            }
            .frame(height: 300)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func open(_ item: ConversationInfo) {
        Navigator.shared.section = .chat
        withAnimation(Motion.settle) { agent.open(item.id) }
        done()
    }
}

/// With the sidebar hidden, what stays of it beside the window buttons, the
/// way notebook apps do: bring the sidebar back, and search.
struct CollapsedChrome: View {
    @State private var searching = false

    var body: some View {
        HStack(spacing: 2) {
            Button { withAnimation(.easeInOut(duration: 0.3)) { Navigator.shared.zen = false } } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(HoverIconStyle(size: 28))
            .tip("Show the sidebar (⌃⌘S)", edge: .bottom)
            Button { searching = true } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(HoverIconStyle(size: 28))
                .keyboardShortcut("k", modifiers: .command)
                .tip("Search conversations (⌘K)", edge: .bottom)
                .popover(isPresented: $searching, arrowEdge: .bottom) {
                    ConversationSearch { searching = false }
                }
        }
        .font(.system(size: 14))
        .padding(.leading, WindowBar.afterButtons)
        .frame(height: WindowBar.height)
        .titleBar()
    }
}
#endif
