import SwiftUI

/// Markdown as a reader would want it: headings, lists, quotes, code and
/// tables laid out as blocks, inline styles and links inside them.
struct MarkdownView: View {
    var text: String
    var size: Size = .body

    enum Size { case body, document }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .document ? 14 : 10) {
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
            Text(Self.inline(text))
                .font(bodyFont)
                .foregroundStyle(Ink.text)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(bodyFont.monospacedDigit())
                            .foregroundStyle(Ink.muted)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(item.text))
                            .font(bodyFont)
                            .foregroundStyle(Ink.text)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
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

    private var bodyFont: Font { size == .document ? .system(size: 15) : .body }

    private func headingFont(_ level: Int) -> Font {
        switch (size, level) {
        case (.document, 1): .system(size: 26, weight: .bold)
        case (.document, 2): .system(size: 20, weight: .bold)
        case (_, 1): .title3.weight(.bold)
        case (_, 2): .headline
        default: .subheadline.weight(.semibold)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
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

private struct TableBlock: View {
    var header: [String]
    var rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownView.inline(cell)).font(.callout.weight(.semibold)).foregroundStyle(Ink.text)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(MarkdownView.inline(cell)).font(.callout).foregroundStyle(Ink.text)
                        }
                    }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ink.surface))
    }
}
