#if os(macOS)
import Foundation

/// The HTML of the artifacts site: an index that works like a repository,
/// and one page per artifact. Web pages are published as they are;
/// documents and tables render their Markdown in the browser; code is
/// highlighted.
enum SitePages {
    static func index(_ entries: [ArtifactPublisher.Entry], domain: String) -> String {
        let rows = entries.map { entry in
            let versions = entry.versions.reversed().map { "<a class=\"v\" href=\"/a/\(entry.slug)/v\($0)/\">v\($0)</a>" }.joined()
            return """
            <li data-title="\(escape(entry.title.lowercased()))">
              <span class="kind \(entry.kind.rawValue)">\(kindName(entry.kind))</span>
              <a class="title" href="/a/\(entry.slug)/">\(escape(entry.title))</a>
              <span class="meta"><time datetime="\(iso(entry.published))">\(iso(entry.published))</time>\(versions)</span>
            </li>
            """
        }.joined(separator: "\n")
        return page(title: "Artifacts", body: """
        <header class="top">
          <div class="brand"><span class="dot"></span>Agott</div>
          <h1>Artifacts</h1>
          <p class="sub">\(entries.count) \(entries.count == 1 ? "item" : "items") · \(escape(domain))</p>
          <input id="q" type="search" placeholder="Search…" autocomplete="off">
        </header>
        <ul class="list" id="list">
        \(rows.isEmpty ? "<li class=\"empty\">Nothing published yet.</li>" : rows)
        </ul>
        <script>
        const q = document.getElementById('q');
        q.addEventListener('input', () => {
          const term = q.value.trim().toLowerCase();
          for (const li of document.querySelectorAll('#list li[data-title]')) {
            li.hidden = term && !li.dataset.title.includes(term);
          }
        });
        for (const t of document.querySelectorAll('time')) {
          t.textContent = new Date(t.dateTime).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
        }
        </script>
        """)
    }

    static func artifact(_ artifact: Card.Artifact, entry: ArtifactPublisher.Entry) -> String {
        if artifact.kind == .html { return artifact.content }
        let source = jsString(artifact.content)
        let header = """
        <header class="doc-top">
          <a class="back" href="/">← Artifacts</a>
          <span class="kind \(artifact.kind.rawValue)">\(kindName(artifact.kind))</span>
          <span class="meta">v\(artifact.version)</span>
        </header>
        """
        switch artifact.kind {
        case .code:
            let language = (artifact.language ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
            return page(title: artifact.title, head: """
            <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
            <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
            """, body: """
            \(header)
            <h1 class="doc-title">\(escape(artifact.title))</h1>
            <pre class="code"><code id="code" class="\(language.isEmpty ? "" : "language-\(language)")"></code></pre>
            <script>
            const el = document.getElementById('code');
            el.textContent = \(source);
            if (window.hljs) hljs.highlightElement(el);
            </script>
            """)
        default:
            return page(title: artifact.title, head: """
            <script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
            """, body: """
            \(header)
            <article class="doc" id="doc"></article>
            <script>
            const src = \(source);
            const doc = document.getElementById('doc');
            if (window.marked) { doc.innerHTML = marked.parse(src); } else { doc.textContent = src; }
            </script>
            """)
        }
    }

    static func notFound() -> String {
        page(title: "Not found", body: """
        <header class="top"><div class="brand"><span class="dot"></span>Agott</div>
        <h1>Not here</h1><p class="sub">This artifact was moved or taken down. <a href="/">See all artifacts</a>.</p></header>
        """)
    }

    // MARK: Pieces

    private static func page(title: String, head: String = "", body: String) -> String {
        """
        <!doctype html>
        <html lang="pt-BR">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex, nofollow">
        <title>\(escape(title))</title>
        <link rel="preconnect" href="https://fonts.googleapis.com">
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Mochiy+Pop+One&display=swap">
        <style>\(css)</style>
        \(head)
        </head>
        <body><main>
        \(body)
        </main></body>
        </html>
        """
    }

    private static let css = """
    :root { --bg:#fbf8f9; --surface:#ffffff; --text:#1d1a1c; --muted:#6f676c; --line:#ece5e9; --spot:#f2559c; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#141216; --surface:#1d1a20; --text:#f3eef1; --muted:#a39aa0; --line:#2b262d; --spot:#ff6aaa; }
    }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
    main { max-width: 760px; margin: 0 auto; padding: 48px 20px 80px; }
    a { color: var(--spot); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .brand { display:flex; align-items:center; gap:8px; font-weight:600; color:var(--muted); font-size:14px; }
    .dot { width:10px; height:10px; border-radius:50%; background:var(--spot); }
    h1, .doc h1 { font-family: "Mochiy Pop One", system-ui, sans-serif; font-weight:400; letter-spacing:-0.01em; }
    .top h1 { font-size: 40px; margin: 12px 0 0; }
    .sub { color: var(--muted); margin: 4px 0 20px; }
    #q { width:100%; padding:12px 16px; border-radius:14px; border:1px solid var(--line); background:var(--surface); color:var(--text); font:inherit; }
    #q:focus { outline: 2px solid var(--spot); outline-offset: 1px; }
    .list { list-style:none; padding:0; margin:24px 0 0; display:grid; gap:8px; }
    .list li { display:grid; grid-template-columns:auto 1fr; gap:4px 12px; align-items:center; padding:14px 16px; border-radius:14px; background:var(--surface); border:1px solid var(--line); transition: transform .15s ease, border-color .15s ease; }
    .list li:hover { border-color: var(--spot); transform: translateY(-1px); }
    .list li.empty { display:block; color:var(--muted); text-align:center; }
    .title { font-weight:600; color: var(--text); }
    .meta { grid-column: 2; color: var(--muted); font-size: 13px; display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
    .v { font-size:12px; padding:1px 7px; border-radius:999px; border:1px solid var(--line); color:var(--muted); }
    .v:hover { border-color: var(--spot); color: var(--spot); text-decoration:none; }
    .kind { grid-row: span 2; font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:.04em; padding:4px 8px; border-radius:8px; background: color-mix(in srgb, var(--spot) 14%, transparent); color: var(--spot); }
    .doc-top { display:flex; align-items:center; gap:12px; margin-bottom: 28px; }
    .doc-top .back { font-weight:600; }
    .doc-top .meta { grid-column:auto; }
    .doc-title { font-size: 30px; margin: 0 0 20px; }
    .doc h1 { font-size: 32px; line-height:1.25; }
    .doc h2 { font-size: 22px; margin-top: 32px; }
    .doc blockquote { margin:0; padding-left:14px; border-left:3px solid var(--spot); color:var(--muted); }
    .doc table { border-collapse: collapse; width:100%; display:block; overflow-x:auto; }
    .doc th, .doc td { padding:8px 12px; border-bottom:1px solid var(--line); text-align:left; }
    .doc code { font: 14px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--surface); padding: 1px 5px; border-radius: 6px; }
    .doc pre { background: var(--surface); padding:16px; border-radius:14px; overflow-x:auto; border:1px solid var(--line); }
    .doc pre code { padding:0; background:none; }
    pre.code { border-radius:14px; overflow:auto; margin:0; }
    pre.code code { font: 14px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; border-radius:14px; }
    @media (max-width: 520px) { .top h1 { font-size: 32px; } main { padding-top: 32px; } }
    """

    private static func kindName(_ kind: Card.Artifact.Kind) -> String {
        switch kind {
        case .document: "Doc"
        case .code: "Code"
        case .html: "Page"
        case .table: "Table"
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A JavaScript string literal that is safe inside a <script> element.
    static func jsString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func iso(_ date: Date) -> String { date.ISO8601Format() }
}
#endif
