#if os(macOS)
import Foundation
import Observation

/// Publishes artifacts to your own site on Cloudflare, as a repository.
///
/// The site is a folder in Application Support: one page per artifact (and
/// per version), an index that lists them all, and a `wrangler.jsonc` that
/// deploys it as a static-assets Worker on your domain. Publishing writes the
/// page, rebuilds the index and runs `wrangler deploy`; wrangler's own login
/// is used, so Agott never holds a Cloudflare token.
@Observable
final class ArtifactPublisher {
    static let shared = ArtifactPublisher()

    struct Entry: Codable, Hashable, Identifiable, Sendable {
        var id: String { key }
        var key: String
        var slug: String
        var title: String
        var kind: Card.Artifact.Kind
        var version: Int
        var versions: [Int]
        var published: Date
    }

    enum PublishError: LocalizedError {
        case noNode
        case deploy(String)

        var errorDescription: String? {
            switch self {
            case .noNode:
                String(localized: "Publishing needs Node.js (for wrangler). Install it, then run “npx wrangler login” once in Terminal.")
            case .deploy(let output):
                String(localized: "wrangler could not deploy: \(output)")
            }
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var publishing: String?

    private let siteURL = URL.applicationSupportDirectory.appending(path: "Agott/Site", directoryHint: .isDirectory)
    private var publicURL: URL { siteURL.appending(path: "public", directoryHint: .isDirectory) }
    private var manifestURL: URL { siteURL.appending(path: "artifacts.json") }

    private init() {
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder.iso.decode([Entry].self, from: data) {
            entries = saved
        }
    }

    var domain: String { AppSettings.shared.publishDomain }

    func entry(for key: String) -> Entry? { entries.first { $0.key == key } }

    func url(for entry: Entry, version: Int? = nil) -> URL? {
        let path = version.map { "a/\(entry.slug)/v\($0)/" } ?? "a/\(entry.slug)/"
        return URL(string: "https://\(domain)/\(path)")
    }

    /// Publishes this version of an artifact and deploys the site.
    @discardableResult
    func publish(_ artifact: Card.Artifact) async throws -> URL {
        publishing = artifact.key
        defer { publishing = nil }

        var entry = entry(for: artifact.key) ?? Entry(
            key: artifact.key, slug: uniqueSlug(for: artifact.title), title: artifact.title,
            kind: artifact.kind, version: artifact.version, versions: [], published: .now)
        entry.title = artifact.title
        entry.kind = artifact.kind
        entry.version = artifact.version
        entry.published = .now
        if !entry.versions.contains(artifact.version) { entry.versions.append(artifact.version) }
        entry.versions.sort()

        let page = SitePages.artifact(artifact, entry: entry)
        try write(page, to: "a/\(entry.slug)/index.html")
        try write(page, to: "a/\(entry.slug)/v\(artifact.version)/index.html")

        var updated = entries.filter { $0.key != entry.key }
        updated.insert(entry, at: 0)
        try await deploy(updated)
        entries = updated
        return url(for: entry)!
    }

    /// Takes an artifact off the site.
    func unpublish(_ key: String) async throws {
        guard let entry = entry(for: key) else { return }
        publishing = key
        defer { publishing = nil }
        try? FileManager.default.removeItem(at: publicURL.appending(path: "a/\(entry.slug)", directoryHint: .isDirectory))
        let updated = entries.filter { $0.key != key }
        try await deploy(updated)
        entries = updated
    }

    // MARK: Site

    private func deploy(_ entries: [Entry]) async throws {
        try FileManager.default.createDirectory(at: publicURL, withIntermediateDirectories: true)
        try write(SitePages.index(entries, domain: domain), to: "index.html")
        try write(SitePages.notFound(), to: "404.html")
        // Personal pages: keep them out of search engines.
        try write("/*\n  X-Robots-Tag: noindex, nofollow\n  Referrer-Policy: no-referrer\n", to: "_headers")
        let config = """
        {
          "name": "\(AppSettings.shared.publishWorker)",
          "compatibility_date": "2026-10-01",
          "assets": { "directory": "./public", "not_found_handling": "404-page" },
          "routes": [{ "pattern": "\(domain)", "custom_domain": true }]
        }
        """
        try config.write(to: siteURL.appending(path: "wrangler.jsonc"), atomically: true, encoding: .utf8)

        try await Self.runWrangler(["deploy"], in: siteURL)

        let data = try JSONEncoder.iso.encode(entries)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func write(_ text: String, to path: String) throws {
        let url = publicURL.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func uniqueSlug(for title: String) -> String {
        let base = Self.slug(title)
        var slug = base
        var n = 2
        while entries.contains(where: { $0.slug == slug }) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }

    nonisolated static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        var slug = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((slug.isEmpty ? "artifact" : slug).prefix(60))
    }

    // MARK: wrangler

    /// Runs wrangler through npx, with the user's own Node and login.
    @concurrent nonisolated static func runWrangler(_ arguments: [String], in directory: URL) async throws {
        guard let npx = findNPX() else { throw PublishError.noNode }
        let process = Process()
        process.executableURL = npx
        process.arguments = ["--yes", "wrangler@4"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = npx.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        environment["CI"] = "1"
        environment["WRANGLER_SEND_METRICS"] = "false"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let output = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output, as: UTF8.self)
            let lines = text.split(separator: "\n").filter { $0.contains("ERROR") || $0.contains("✘") || $0.contains("error") }
            throw PublishError.deploy(String((lines.isEmpty ? String(text.suffix(400)) : lines.prefix(4).joined(separator: " ")).prefix(400)))
        }
    }

    nonisolated static func findNPX() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        for root in ["\(home)/.local/share/mise/installs/node", "\(home)/.nvm/versions/node", "\(home)/.asdf/installs/nodejs"] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append("\(root)/\(version)/bin/npx")
            }
        }
        candidates += ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "\(home)/.volta/bin/npx"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
#endif
