#if os(macOS)
import Foundation
import FoundationModels

/// Watches a video for the model: its title, chapters and description, and
/// what is said in it. The words come from the video's own subtitles when it
/// has them (fast), else its audio is fetched and transcribed on this Mac with
/// Parakeet. yt-dlp does the fetching (the user's own install, from Homebrew).
nonisolated enum VideoReader {
    enum Problem: LocalizedError {
        case noYtDlp
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noYtDlp: "yt-dlp is not installed. The user can install it with “brew install yt-dlp” in Terminal."
            case .failed(let why): why
            }
        }
    }

    struct Video: Sendable {
        var title: String
        var channel: String?
        var duration: Int?
        var description: String
        var chapters: [(start: Int, title: String)]
        var transcript: String?
        /// Where the words came from: "subtitles" or "audio".
        var source: String?
    }

    /// Characters of transcript that go to the model.
    static let transcriptBudget = 30_000

    static func read(_ url: URL) async throws -> Video {
        guard let ytdlp = find("yt-dlp") else { throw Problem.noYtDlp }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Agott video \(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var video = try await metadata(url, ytdlp: ytdlp, in: folder)
        if let words = try? await subtitles(url, ytdlp: ytdlp, in: folder), !words.isEmpty {
            video.transcript = words
            video.source = "subtitles"
        } else if let words = try await audioTranscript(url, ytdlp: ytdlp, in: folder) {
            video.transcript = words
            video.source = "audio"
        }
        return video
    }

    // MARK: Steps

    private static func metadata(_ url: URL, ytdlp: URL, in folder: URL) async throws -> Video {
        let json = try await run(ytdlp, ["--dump-single-json", "--skip-download", "--no-playlist", "--no-warnings", url.absoluteString],
                                 in: folder, limit: .seconds(60))
        guard let start = json.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any] else {
            throw Problem.failed("yt-dlp could not read that video.")
        }
        let chapters = (object["chapters"] as? [[String: Any]] ?? []).compactMap { chapter -> (Int, String)? in
            guard let title = chapter["title"] as? String else { return nil }
            return (Int(chapter["start_time"] as? Double ?? 0), title)
        }
        return Video(
            title: object["title"] as? String ?? url.absoluteString,
            channel: (object["channel"] ?? object["uploader"]) as? String,
            duration: (object["duration"] as? Double).map(Int.init),
            description: object["description"] as? String ?? "",
            chapters: chapters.map { (start: $0.0, title: $0.1) })
    }

    /// The video's own subtitles: written ones first, else the automatic
    /// ones in the language it is spoken in.
    private static func subtitles(_ url: URL, ytdlp: URL, in folder: URL) async throws -> String? {
        _ = try await run(ytdlp, ["--skip-download", "--no-playlist", "--no-warnings", "--write-subs", "--write-auto-subs",
                                  "--sub-langs", "pt,pt-BR,en,.*-orig", "--sub-format", "vtt",
                                  "-o", folder.appending(path: "video.%(ext)s").path, url.absoluteString],
                          in: folder, limit: .seconds(90))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let vtts = files.filter { $0.pathExtension == "vtt" }
        // Written subtitles carry no "-orig"; prefer them, then Portuguese.
        let chosen = vtts.sorted { rank($0) < rank($1) }.first
        guard let chosen, let text = try? String(contentsOf: chosen, encoding: .utf8) else { return nil }
        return clean(vtt: text)
    }

    private static func rank(_ file: URL) -> Int {
        let name = file.lastPathComponent
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        var rank = name.contains("-orig") ? 10 : 0
        if !name.contains(".\(preferred)") { rank += 1 }
        return rank
    }

    /// No subtitles: the audio, transcribed here.
    private static func audioTranscript(_ url: URL, ytdlp: URL, in folder: URL) async throws -> String? {
        guard Parakeet.isInstalled else {
            throw Problem.failed("This video has no subtitles, and the transcription model is not downloaded yet (Settings › Voice).")
        }
        var arguments = ["--no-playlist", "--no-warnings", "-f", "bestaudio[ext=m4a]/bestaudio",
                         "-o", folder.appending(path: "audio.%(ext)s").path]
        if let ffmpeg = find("ffmpeg") {
            arguments += ["-x", "--audio-format", "m4a", "--ffmpeg-location", ffmpeg.path]
        }
        _ = try await run(ytdlp, arguments + [url.absoluteString], in: folder, limit: .seconds(300))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let audio = files.first(where: { $0.lastPathComponent.hasPrefix("audio.") && $0.pathExtension != "part" }) else {
            throw Problem.failed("yt-dlp could not fetch the video's audio.")
        }
        let language = await Parakeet.language(for: AppSettings.shared.speechLocale)
        let words = await Deadline.run(.seconds(600)) { try? await Parakeet.shared.transcribe(file: audio, language: language) } ?? nil
        guard let words, !words.isEmpty else { throw Problem.failed("The audio could not be transcribed.") }
        return words
    }

    // MARK: Subtitles

    /// A WebVTT file as plain text: no header, cue settings or inline tags,
    /// the rolling repeats of automatic captions said once, and a time mark
    /// about every half minute so the model can say where something is.
    static func clean(vtt: String) -> String {
        var lines: [String] = []
        var seen = Set<String>()
        var lastMark = -30
        var cueStart = 0
        for raw in vtt.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || line.hasPrefix("Kind:") || line.hasPrefix("Language:")
                || line.hasPrefix("NOTE") || line.allSatisfy(\.isNumber) { continue }
            if line.contains("-->") {
                cueStart = seconds(String(line.prefix { $0 != " " }))
                continue
            }
            let text = line.replacing(/<[^>]+>/, with: "")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, seen.insert(text).inserted else { continue }
            if cueStart - lastMark >= 30 {
                lines.append("[\(cueStart / 60):\(String(format: "%02d", cueStart % 60))]")
                lastMark = cueStart
            }
            lines.append(text)
        }
        return lines.joined(separator: " ").replacingOccurrences(of: " [", with: "\n[")
    }

    /// "00:01:02.500" or "01:02.500" in whole seconds.
    static func seconds(_ stamp: String) -> Int {
        let parts = stamp.split(separator: ":").map { Double($0) ?? 0 }
        return Int(parts.reduce(0) { $0 * 60 + $1 })
    }

    // MARK: Running

    static func find(_ tool: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "\(home)/.local/bin/\(tool)",
                "\(home)/.local/share/mise/shims/\(tool)", "/usr/bin/\(tool)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private static func run(_ executable: URL, _ arguments: [String], in folder: URL, limit: Duration) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        async let stdout = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        async let stderr = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        // Too long: stop it, which also ends the reads above.
        let watchdog = Task.detached {
            try? await Task.sleep(for: limit)
            if process.isRunning { process.terminate() }
        }
        let (output, errors) = await (stdout, stderr)
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self)
                .split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
                ?? String(localized: "yt-dlp stopped without saying why.")
            throw Problem.failed(String(message.prefix(300)))
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// "Watch this video": what a YouTube (or other) video says, for instructions,
/// recipes, workouts, lessons.
nonisolated struct WatchVideoTool: Tool {
    let name = "watch_video"
    let description = """
    Watch a video from a link (YouTube, Instagram, TikTok, Vimeo…): returns its title, channel, length, chapters, \
    description and a transcript of what is said, with time marks. Use it when the user shares a video or asks what \
    one says or teaches, e.g. to take the exercises out of a workout video.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The video's full http or https address")
        var url: String
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        guard let url = URL(string: arguments.url.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "That is not a video address."
        }
        do {
            let video = try await VideoReader.read(url)
            var parts = ["Title: \(video.title)"]
            if let channel = video.channel { parts.append("Channel: \(channel)") }
            if let duration = video.duration { parts.append("Length: \(duration / 60) min \(duration % 60) s") }
            if !video.chapters.isEmpty {
                parts.append("Chapters:\n" + video.chapters.map { "\($0.start / 60):\(String(format: "%02d", $0.start % 60)) \($0.title)" }.joined(separator: "\n"))
            }
            if !video.description.isEmpty { parts.append("Description:\n\(video.description.prefix(4000))") }
            if let transcript = video.transcript {
                parts.append("Transcript (from the video's \(video.source ?? "audio")):\n\(transcript.prefix(VideoReader.transcriptBudget))")
            } else {
                parts.append("No transcript could be made.")
            }
            return parts.joined(separator: "\n\n")
        } catch {
            return "Could not watch the video: \(error.localizedDescription)"
        }
    }
}
#endif
