import SwiftUI

/// Markdown as a reader would want it: headings, lists, quotes, code and
/// tables laid out as blocks, inline styles and links inside them.
struct MarkdownView: View {
    var text: String
    var size: Size = .body

    enum Size { case body, document, zen }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .body ? 10 : 14) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(headingFont(level))
                .foregroundStyle(Ink.text)
                .padding(.top, level == 1 ? 6 : 2)
        case .paragraph(let text):
            if Self.mentionsPeople(text) {
                // People named here become chips with their avatar and card.
                MentionParagraph(text: text)
                    .font(bodyFont)
                    .foregroundStyle(Ink.text)
            } else {
                Text(Self.inline(text))
                    .font(bodyFont)
                    .foregroundStyle(Ink.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(bodyFont.monospacedDigit())
                            .foregroundStyle(Ink.muted)
                            .frame(minWidth: 14, alignment: .trailing)
                        if Self.mentionsPeople(item.text) {
                            MentionParagraph(text: item.text)
                                .font(bodyFont)
                                .foregroundStyle(Ink.text)
                        } else {
                            Text(Self.inline(item.text))
                                .font(bodyFont)
                                .foregroundStyle(Ink.text)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let text):
            Text(Self.inline(text))
                .font(bodyFont)
                .foregroundStyle(Ink.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Ink.spot.opacity(0.6)).frame(width: 3)
                }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Ink.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private var bodyFont: Font {
        switch size {
        case .body: .body
        case .document: .system(size: 15)
        case .zen: .system(size: 16)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch (size, level) {
        case (.document, 1): .system(size: 26, weight: .bold)
        case (.document, 2): .system(size: 20, weight: .bold)
        case (.zen, 1): .system(size: 24, weight: .bold)
        case (.zen, _): .system(size: 20, weight: .semibold)
        case (_, 1): .title3.weight(.bold)
        case (_, 2): .headline
        default: .subheadline.weight(.semibold)
        }
    }

    /// Whether a block names people with tags (`<e id=12/>`).
    static func mentionsPeople(_ text: String) -> Bool {
        text.contains("<e id=") || text.contains("<media")
    }

    static func inline(_ text: String) -> AttributedString {
        // People and groups arrive as tags; they become pink names (or
        // "Person 12" with names hidden).
        let prepared = EntityText.markdown(text, hidden: AppSettings.shared.hideNames)
        var result = (try? AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(prepared)
        EntityText.style(&result)
        return result
    }
}

/// The blocks of a Markdown text, parsed line by line. Forgiving: anything
/// it does not recognise is a paragraph.
enum MarkdownBlock: Hashable {
    struct Item: Hashable { var text: String; var depth: Int }

    case heading(Int, String)
    case paragraph(String)
    case list(ordered: Bool, items: [Item])
    case quote(String)
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [Item])?
        var quote: [String] = []
        var table: [[String]] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if let current = list { blocks.append(.list(ordered: current.ordered, items: current.items)); list = nil }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty {
                let header = table[0]
                let body = table.dropFirst().filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
                blocks.append(.table(header: header, rows: Array(body)))
                table = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { index += 1 }

            if trimmed.hasPrefix("```") {
                flush()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                if table.isEmpty { flush() }
                table.append(trimmed.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            } else if !table.isEmpty {
                flush()
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); blocks.append(.rule); continue }
            if let level = headingLevel(trimmed) {
                flush()
                blocks.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                continue
            }
            if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            let depth = (line.prefix(while: { $0 == " " }).count) / 2
            if let item = bullet(trimmed) {
                if list?.ordered != false { flush(); list = (false, []) }
                list?.items.append(Item(text: item, depth: depth))
                continue
            }
            if let item = numbered(trimmed) {
                if list?.ordered != true { flush(); list = (true, []) }
                list?.items.append(Item(text: item, depth: depth))
                continue
            }
            if list != nil, line.hasPrefix("  "), var current = list, !current.items.isEmpty {
                // A wrapped list item continues on an indented line.
                current.items[current.items.count - 1].text += " " + trimmed
                list = current
                continue
            }
            if !quote.isEmpty || list != nil { flush() }
            paragraph.append(trimmed)
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return min(hashes, 3)
    }

    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> String? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count < 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }
}

struct CodeBlock: View {
    var language: String?
    var code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption.weight(.semibold)).foregroundStyle(Ink.muted)
                Spacer()
                Button {
                    Clipboard.copy(code)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 4)
                }
                .buttonStyle(HoverIconStyle(size: 22))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Ink.text)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.never)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
    }
}

/// A Markdown table drawn as a table: a header band, hairline rows,
/// numbers right-aligned, a leading rank column quieted, pictures in cells
/// (`![](url)`) shown as thumbnails, and a copy button on hover.
private struct TableBlock: View {
    var header: [String]
    var rows: [[String]]
    @State private var hovering = false
    @State private var copied = false
    @State private var width: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        cell(header[safe: column] ?? "", column: column, isHeader: true)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    Rectangle().fill(Ink.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            cell(row[safe: column] ?? "", column: column, isHeader: false)
                        }
                    }
                }
            }
            // At least as wide as the card, so the header band and the rows
            // reach its edge; wider tables scroll.
            .frame(minWidth: width, alignment: .leading)
            // One band behind the whole header row, not one per cell.
            .background(alignment: .top) { Ink.raised.frame(height: headerHeight) }
        }
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .clipShape(shape)
        .quietSurface(shape)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    Clipboard.copy(markdown)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(HoverIconStyle(size: 24))
                .padding(4)
                .help(Text("Copy table"))
                .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }

    @ViewBuilder
    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        let rankColumn = column == 0 && isRankColumn
        let numeric = numericColumns.contains(column) && !rankColumn
        let rank = !isHeader && rankColumn
        Group {
            if !isHeader, let image = Self.image(in: text) {
                HStack(spacing: 8) {
                    Artwork(url: image.url, kind: "other", size: 36)
                    if !image.rest.isEmpty { Text(MarkdownView.inline(image.rest)) }
                }
            } else {
                Text(MarkdownView.inline(text))
            }
        }
        .font(isHeader ? .caption.weight(.semibold) : (rank ? Lettering.display(15, relativeTo: .callout) : .callout))
        .monospacedDigit()
        .foregroundStyle(isHeader || rank ? Ink.muted : Ink.text)
        // Only text columns take the spare width; a rank stays a narrow
        // gutter and numbers stay as wide as they are, right-aligned.
        .frame(maxWidth: rankColumn || numeric ? nil : .infinity, alignment: numeric ? .trailing : .leading)
        .fixedSize(horizontal: rankColumn || numeric, vertical: false)
        .gridColumnAlignment(numeric ? .trailing : .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, isHeader ? 7 : 9)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if isHeader { headerHeight = max(headerHeight, height) }
        }
    }

    /// Columns whose every filled cell reads as a number ("12", "3,5", "R$ 40", "87%").
    private var numericColumns: Set<Int> {
        Set((0..<columns).filter { column in
            let values = rows.compactMap { $0[safe: column] }.filter { !$0.isEmpty }
            return !values.isEmpty && values.allSatisfy(Self.isNumber)
        })
    }

    /// A first column that just counts 1, 2, 3…
    private var isRankColumn: Bool {
        rows.count > 1 && rows.enumerated().allSatisfy { index, row in
            (row.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .º°#")) == "\(index + 1)"
        }
    }

    nonisolated static func isNumber(_ text: String) -> Bool {
        let core = text.replacingOccurrences(of: "R$", with: "").replacingOccurrences(of: "US$", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " %$€£+-*x×h"))
        return !core.isEmpty && core.allSatisfy { $0.isNumber || ".,: ".contains($0) }
    }

    /// `![alt](url) rest` in a cell: the picture and what follows it.
    static func image(in text: String) -> (url: URL, rest: String)? {
        guard let match = text.firstMatch(of: /!\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/),
              let url = URL(string: String(match.1)) else { return nil }
        var rest = text
        rest.removeSubrange(match.range)
        return (url, rest.trimmingCharacters(in: .whitespaces))
    }

    private var markdown: String {
        let line = { (cells: [String]) in "| " + cells.joined(separator: " | ") + " |" }
        return ([line(header), line(header.map { _ in "---" })] + rows.map(line)).joined(separator: "\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
