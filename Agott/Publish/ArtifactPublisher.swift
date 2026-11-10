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

    /// A Cloudflare account your wrangler login can deploy to.
    struct Account: Decodable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
    }

    enum PublishError: LocalizedError {
        case noNode
        case notLoggedIn
        /// The login reaches several accounts and none is chosen yet.
        case chooseAccount([Account])
        case deploy(String)

        var errorDescription: String? {
            switch self {
            case .noNode:
                String(localized: "Publishing needs Node.js (for wrangler). Install it, then run “npx wrangler login” once in Terminal.")
            case .notLoggedIn:
                String(localized: "wrangler is not logged in to Cloudflare. Run “npx wrangler login” once in Terminal.")
            case .chooseAccount:
                String(localized: "Your Cloudflare login has more than one account. Choose the one with your site in Settings › Connections.")
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
        let account = try await Self.account()
        let config = """
        {
          "name": "\(AppSettings.shared.publishWorker)",
          "account_id": "\(account)",
          "compatibility_date": "2026-10-01",
          "assets": { "directory": "./public", "not_found_handling": "404-page" },
          "routes": [{ "pattern": "\(domain)", "custom_domain": true }]
        }
        """
        try config.write(to: siteURL.appending(path: "wrangler.jsonc"), atomically: true, encoding: .utf8)

        _ = try await Self.runWrangler(["deploy"], in: siteURL, account: account)

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

    /// The account to deploy to: the one chosen in Settings, else the only
    /// one the login reaches. Several and none chosen: the caller asks.
    private static func account() async throws -> String {
        let chosen = AppSettings.shared.publishAccount
        if !chosen.isEmpty { return chosen }
        let accounts = try await accounts()
        switch accounts.count {
        case 0: throw PublishError.notLoggedIn
        case 1:
            AppSettings.shared.publishAccount = accounts[0].id
            return accounts[0].id
        default: throw PublishError.chooseAccount(accounts)
        }
    }

    /// The accounts wrangler's login can deploy to.
    static func accounts() async throws -> [Account] {
        struct WhoAmI: Decodable {
            var loggedIn: Bool
            var accounts: [Account]?
        }
        let output: String
        do {
            output = try await runWrangler(["whoami", "--json"], in: FileManager.default.temporaryDirectory)
        } catch PublishError.deploy {
            // whoami --json fails when nobody is logged in.
            throw PublishError.notLoggedIn
        }
        // npx may print a line of its own before the JSON.
        guard let start = output.firstIndex(of: "{"),
              let who = try? JSONDecoder().decode(WhoAmI.self, from: Data(output[start...].utf8)),
              who.loggedIn else { throw PublishError.notLoggedIn }
        return (who.accounts ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Runs wrangler through npx, with the user's own Node and login, and
    /// returns what it printed on standard output.
    @discardableResult
    @concurrent nonisolated static func runWrangler(_ arguments: [String], in directory: URL, account: String? = nil) async throws -> String {
        guard let npx = findNPX() else { throw PublishError.noNode }
        let process = Process()
        process.executableURL = npx
        process.arguments = ["--yes", "wrangler@4"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = npx.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        environment["CI"] = "1"
        environment["WRANGLER_SEND_METRICS"] = "false"
        // Plain text: no colour codes in what we read back.
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        if let account { environment["CLOUDFLARE_ACCOUNT_ID"] = account }
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        // Both read at once, so a full pipe never stalls wrangler.
        async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        let (output, errors) = await (stdout, stderr)
        process.waitUntilExit()
        let printed = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PublishError.deploy(failure(in: printed + "\n" + String(decoding: errors, as: UTF8.self)))
        }
        return printed
    }

    /// The lines that say what went wrong, without colour codes or wrangler's
    /// own decoration.
    nonisolated static func failure(in output: String) -> String {
        let clean = output
            .replacing(/\x1B\[[0-9;?]*[A-Za-z]/, with: "")
            .replacing(/\[[0-9;]*m/, with: "")
        let lines = clean.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = lines.filter { $0.contains("ERROR") || $0.hasPrefix("✘") || $0.localizedCaseInsensitiveContains("error") }
            .map { $0.replacing(/^✘\s*/, with: "").replacing(/^\[ERROR\]\s*/, with: "") }
        let text = errors.isEmpty ? lines.suffix(4).joined(separator: " ") : errors.prefix(4).joined(separator: " ")
        return String(text.prefix(400))
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
