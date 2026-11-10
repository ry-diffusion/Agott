import Foundation

/// How web pages Agott writes look: the app's quiet notebook on the web.
///
/// Neutral greys from `Ink.Tone`, a serif for headlines and the system face
/// elsewhere, hairline cards and one colour, the system purple. The sheet
/// goes in front of a page's own styles, so a page that styles itself still
/// can, and a plain page looks like Agott without trying.
nonisolated enum ArtifactStyle {
    /// Colours, type and radii as CSS variables, for light and dark.
    static var tokens: String {
        """
        :root {
          color-scheme: light dark;
          \(variables(\.light))
          --serif: ui-serif, "New York", "Iowan Old Style", Georgia, "Times New Roman", serif;
          --sans: -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
          --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
          --radius: 14px;
          --radius-sm: 10px;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            \(variables(\.dark))
          }
        }
        """
    }

    /// The whole sheet: the tokens, plain elements, and the few classes
    /// the artifact tool tells the model about.
    static var css: String {
        tokens + "\n" + """
        *, *::before, *::after { box-sizing: border-box; }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.6 var(--sans); -webkit-font-smoothing: antialiased; }
        main, .page { max-width: 760px; margin: 0 auto; padding: 40px 20px 72px; }
        h1, h2 { font-family: var(--serif); font-weight: 400; letter-spacing: -0.01em; line-height: 1.2; }
        h1 { font-size: 34px; margin: 0 0 12px; }
        h2 { font-size: 23px; margin: 32px 0 10px; }
        h3, h4, h5, h6 { font-family: var(--sans); font-weight: 600; line-height: 1.35; margin: 24px 0 6px; }
        h3 { font-size: 16px; }
        h4, h5, h6 { font-size: 14px; color: var(--muted); }
        p { margin: 0 0 14px; }
        a { color: var(--spot); text-decoration: none; }
        a:hover { text-decoration: underline; }
        strong, b { font-weight: 600; }
        small, .muted { color: var(--muted); }
        .lede { font-size: 18px; color: var(--muted); margin-bottom: 24px; }
        .eyebrow { font-size: 12px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--muted); }
        .spot { color: var(--spot); }
        hr { border: 0; border-top: 1px solid var(--line); margin: 28px 0; }
        blockquote { margin: 0 0 14px; padding-left: 14px; border-left: 2px solid var(--line); color: var(--muted); }
        ul, ol { padding-left: 22px; margin: 0 0 14px; }
        li { margin: 4px 0; }
        table { border-collapse: collapse; width: 100%; font-size: 15px; margin: 0 0 16px; }
        th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid var(--line); vertical-align: top; }
        th { font-size: 13px; font-weight: 600; color: var(--muted); }
        code, kbd, samp, pre { font-family: var(--mono); font-size: 14px; }
        :not(pre) > code { background: var(--raised); padding: 1px 5px; border-radius: 6px; }
        pre { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 14px 16px; overflow-x: auto; line-height: 1.5; }
        img, svg, video, canvas { max-width: 100%; height: auto; }
        button, .button { display: inline-flex; align-items: center; gap: 6px; font: 600 14px/1 var(--sans); color: var(--text); background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: 9px 14px; cursor: pointer; text-decoration: none; }
        button:hover, .button:hover { background: var(--raised); text-decoration: none; }
        button.primary, .button.primary { background: var(--spot); border-color: transparent; color: #fff; }
        input, select, textarea { font: 15px/1.4 var(--sans); color: var(--text); background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-sm); padding: 9px 12px; }
        :focus-visible { outline: 2px solid var(--spot); outline-offset: 2px; }
        .card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); padding: 16px 18px; }
        .grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
        .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
        .stack > * + * { margin-top: 12px; }
        .pill { display: inline-block; font-size: 12px; font-weight: 600; line-height: 1.6; padding: 1px 9px; border-radius: 999px; background: var(--raised); color: var(--muted); }
        .pill.spot { background: color-mix(in srgb, var(--spot) 14%, transparent); color: var(--spot); }
        @media (max-width: 520px) { main, .page { padding-top: 28px; } h1 { font-size: 28px; } }
        """
    }

    /// What the artifact tool tells the model about the sheet.
    static let guidance = """
    Agott adds its own stylesheet to every html page: neutral greys, a serif h1/h2, the system font, \
    one purple accent, light and dark mode. Write plain semantic HTML (main, h1, h2, p, table, ul, button) \
    and use its classes .card, .grid, .row, .stack, .pill, .muted, .lede, .eyebrow, .spot, button.primary. \
    For any colour use var(--bg), var(--surface), var(--raised), var(--text), var(--muted), var(--line), \
    var(--spot) (charts read them with getComputedStyle). No palette, fonts, gradients, glows or dark theme of your own.
    """

    /// A page with the sheet in front of its own styles. A fragment gets a
    /// whole page around it.
    static func page(_ html: String, title: String) -> String {
        let sheet = "<style id=\"agott-style\">\n\(css)\n</style>"
        if let head = html.firstRange(of: /<head\b[^>]*>/.ignoresCase()) {
            return String(html[..<head.upperBound]) + "\n" + sheet + String(html[head.upperBound...])
        }
        if let root = html.firstRange(of: /<html\b[^>]*>/.ignoresCase()) {
            return String(html[..<root.upperBound]) + "\n<head>\(sheet)</head>" + String(html[root.upperBound...])
        }
        let body = html.contains(/<body\b/.ignoresCase()) ? html : "<body>\n\(html)\n</body>"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(ArtifactNames.escapeHTML(title))</title>
        \(sheet)
        </head>
        \(body)
        </html>
        """
    }

    // MARK: Pieces

    private static func variables(_ mode: KeyPath<Ink.Tone.Pair, Ink.Tone.RGB>) -> String {
        let pairs: [(String, Ink.Tone.Pair)] = [
            ("bg", Ink.Tone.canvas), ("surface", Ink.Tone.surface), ("raised", Ink.Tone.raised),
            ("text", Ink.Tone.text), ("muted", Ink.Tone.muted), ("line", Ink.Tone.hairline), ("spot", Ink.Tone.spot),
        ]
        return pairs.map { "--\($0.0): \(hex($0.1[keyPath: mode]));" }.joined(separator: " ")
    }

    static func hex(_ rgb: Ink.Tone.RGB) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(rgb.0), byte(rgb.1), byte(rgb.2))
    }
}
