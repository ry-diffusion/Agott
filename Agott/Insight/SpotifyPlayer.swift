#if os(macOS)
import AppKit
import Foundation
import FoundationModels

/// Plays through the Spotify app on this Mac: a track, album, artist or
/// playlist by its URI, and pause, resume, next, previous. The app's own
/// scripting does it, so no Premium and no extra Spotify permission; macOS
/// asks once whether Agott may control Spotify.
nonisolated enum SpotifyPlayer {
    enum Failure: LocalizedError {
        case notInstalled

        var errorDescription: String? { String(localized: "The Spotify app is not on this Mac.") }
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    static func play(uri: String) async throws {
        guard isInstalled else { throw Failure.notInstalled }
        let safe = uri.filter { $0.isLetter || $0.isNumber || $0 == ":" }
        _ = try await AppleScriptRunner.run("tell application \"Spotify\" to play track \"\(safe)\"", timeout: 10)
    }

    enum Command: String { case pause, play, next = "next track", previous = "previous track", toggle = "playpause" }

    static func send(_ command: Command) async throws {
        guard isInstalled else { throw Failure.notInstalled }
        _ = try await AppleScriptRunner.run("tell application \"Spotify\" to \(command.rawValue)", timeout: 10)
    }

    /// "Song — Artist", or nil when nothing is playing.
    static func nowPlaying() async -> String? {
        let script = """
        tell application "Spotify"
            if player state is playing then return (name of current track) & " — " & (artist of current track)
        end tell
        return ""
        """
        let text = (try? await AppleScriptRunner.run(script, timeout: 5)) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Plays what someone named: their search on Spotify, then the app.
    /// Without a Spotify sign-in, the app opens on the search instead.
    @MainActor
    static func play(_ query: String, kind: String) async throws -> String {
        let type = switch kind {
        case "album": "album"
        case "artist": "artist"
        case "playlist": "playlist"
        default: "track"
        }
        if SpotifyAccount.shared.isConnected, let found = try await SpotifyAccount.shared.search(query, type: type) {
            try await play(uri: found.uri)
            return found.subtitle.isEmpty ? found.title : "\(found.title) — \(found.subtitle)"
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        if let url = URL(string: "spotify:search:\(encoded)") { NSWorkspace.shared.open(url) }
        return String(localized: "the search for \(query)")
    }
}

/// Plays music on Spotify, or pauses, resumes and skips.
nonisolated struct SpotifyPlayTool: Tool {
    let name = "spotify_play"
    let description = """
    Control Spotify on this Mac: play a song, album, artist or playlist by name, or pause, resume, skip to the \
    next or go back. Use it when the user asks to play, put on, pause or skip music.
    """

    @Generable
    struct Arguments {
        var action: Action
        @Guide(description: "For play: what to play, e.g. \"Alors on danse Stromae\" or \"lo-fi para estudar\"")
        var query: String?
        @Guide(description: "For play: what the query names")
        var kind: Kind?

        @Generable
        enum Action { case play, pause, resume, next, previous }

        @Generable
        enum Kind { case track, album, artist, playlist }
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        do {
            switch arguments.action {
            case .play:
                guard let query = arguments.query, !query.isEmpty else {
                    try await SpotifyPlayer.send(.play)
                    return "Resumed Spotify."
                }
                let kind = arguments.kind.map { "\($0)" } ?? "track"
                let playing = try await SpotifyPlayer.play(query, kind: kind)
                return "Playing \(playing) on Spotify. Say so in a few words."
            case .pause:
                try await SpotifyPlayer.send(.pause)
                return "Paused Spotify."
            case .resume:
                try await SpotifyPlayer.send(.play)
                return "Resumed Spotify."
            case .next:
                try await SpotifyPlayer.send(.next)
                return "Skipped to the next track" + ((await SpotifyPlayer.nowPlaying()).map { ": \($0)." } ?? ".")
            case .previous:
                try await SpotifyPlayer.send(.previous)
                return "Went back" + ((await SpotifyPlayer.nowPlaying()).map { ": \($0)." } ?? ".")
            }
        } catch {
            return "Spotify could not do that: \(error.localizedDescription)"
        }
    }
}
#endif
