import Foundation
import FoundationModels
import Observation
#if os(macOS)
import AppKit
#endif

/// What you listen to, and what it says about how you feel.
///
/// Every half minute Agott asks Spotify (or Apple Music) what is playing,
/// only if the app is already open, so it never launches it. Each new track
/// is logged. The on-device model labels a track's mood once (from what it
/// knows about the song and artist) and the label is cached, so a song you
/// loop costs nothing. The log lines up with your messages: the tone of what
/// you wrote while a kind of music was playing is the interesting part.
nonisolated struct Play: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(date.timeIntervalSince1970)|\(track)" }
    var date: Date
    var track: String
    var artist: String
    var album: String
    var app: String
}

nonisolated struct TrackMood: Codable, Hashable, Sendable {
    var mood: String
    var energy: Int
    var valence: Int
    var genre: String
}

#if os(macOS)
@Observable
final class MusicListener {
    static let shared = MusicListener()

    private(set) var nowPlaying: Play?
    private(set) var nowMood: TrackMood?
    @ObservationIgnored private var timer: Task<Void, Never>?

    private init() {}

    var isEnabled: Bool { AppSettings.shared.listenToMusic }

    func start() {
        guard timer == nil else { return }
        timer = Task(priority: .utility) {
            while !Task.isCancelled {
                if isEnabled { await poll() }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private static let players: [(bundle: String, app: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music"),
    ]

    private func poll() async {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for player in Self.players where running.contains(player.bundle) {
            let script = """
            tell application "\(player.app)"
                if player state is playing then
                    return (name of current track) & "\\u001F" & (artist of current track) & "\\u001F" & (album of current track)
                end if
            end tell
            return ""
            """
            guard let output = try? await AppleScriptRunner.run(script), !output.isEmpty else { continue }
            let parts = output.components(separatedBy: "\u{1F}")
            guard parts.count >= 3, !parts[0].isEmpty else { continue }
            let play = Play(date: .now, track: parts[0], artist: parts[1], album: parts[2],
                            app: player.app == "Music" ? "Apple Music" : player.app)
            if play.track != nowPlaying?.track || play.artist != nowPlaying?.artist {
                nowPlaying = play
                try? await MemoryStore.shared.logPlay(play)
                nowMood = await MusicMood.mood(of: play)
            }
            return
        }
        nowPlaying = nil
        nowMood = nil
    }
}

enum MusicMood {
    @Generable
    struct Label {
        @Guide(description: "The feeling of the song in one word, in English: happy, calm, sad, angry, romantic, nostalgic, energetic, anxious, dreamy, focused, defiant, playful")
        var mood: String
        @Guide(description: "How energetic it is, 0 to 100", .range(0...100))
        var energy: Int
        @Guide(description: "How positive it feels, 0 (dark) to 100 (bright)", .range(0...100))
        var valence: Int
        @Guide(description: "The genre in one or two words")
        var genre: String
    }

    /// The mood of a track, from the cache or labelled once.
    static func mood(of play: Play) async -> TrackMood? {
        let key = "mood:\(play.artist.folded)|\(play.track.folded)"
        if let (json, _) = try? await MemoryStore.shared.insight(key: key),
           let cached = try? JSONDecoder().decode(TrackMood.self, from: Data(json.utf8)) {
            return cached
        }
        guard let label = try? await ModelHub.generate(
            Label.self,
            prompt: "Song: \"\(play.track)\" by \(play.artist), album \"\(play.album)\".",
            instructions: "You describe how a song feels from what you know of it and its artist. If you do not know it, judge from the title, artist and album.",
            provider: ModelHub.bulkProvider)
        else { return nil }
        let mood = TrackMood(mood: label.mood.lowercased(), energy: label.energy, valence: label.valence, genre: label.genre)
        if let data = try? JSONEncoder().encode(mood), let json = String(data: data, encoding: .utf8) {
            try? await MemoryStore.shared.saveInsight(json, key: key)
        }
        return mood
    }

    struct Summary: Sendable {
        var plays: Int
        var moods: [(String, Int)]
        var topArtists: [(String, Int)]
        var averageValence: Double?
        var averageEnergy: Double?
        /// Tone of your own messages while each mood was playing (-1…1).
        var toneByMood: [(String, Double)]
        var lateNightShare: Double
    }

    /// Listening over the last `days`, with moods and the tone of what you
    /// wrote while they played.
    static func summary(days: Int = 14) async -> Summary {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let plays = (try? await MemoryStore.shared.plays(since: since)) ?? []
        var moodCount: [String: Int] = [:]
        var artistCount: [String: Int] = [:]
        var valences: [Double] = [], energies: [Double] = []
        var toneSamples: [String: [Double]] = [:]
        var late = 0
        for play in plays {
            artistCount[play.artist, default: 0] += 1
            let hour = Calendar.current.component(.hour, from: play.date)
            if hour >= 23 || hour < 5 { late += 1 }
            guard let mood = await mood(of: play) else { continue }
            moodCount[mood.mood, default: 0] += 1
            valences.append(Double(mood.valence))
            energies.append(Double(mood.energy))
            // What you wrote within twenty minutes of the song.
            let mine = (try? await MemoryStore.shared.myMessages(
                from: play.date.addingTimeInterval(-600), to: play.date.addingTimeInterval(1200))) ?? []
            if !mine.isEmpty {
                toneSamples[mood.mood, default: []].append(Consistency.tone(mine))
            }
        }
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return Summary(
            plays: plays.count,
            moods: moodCount.sorted { $0.value > $1.value },
            topArtists: Array(artistCount.sorted { $0.value > $1.value }.prefix(6)),
            averageValence: average(valences), averageEnergy: average(energies),
            toneByMood: toneSamples.compactMap { mood, values in average(values).map { (mood, $0) } }.sorted { $0.1 > $1.1 },
            lateNightShare: plays.isEmpty ? 0 : Double(late) / Double(plays.count))
    }

    static func describe(_ summary: Summary) -> String {
        guard summary.plays > 0 else { return "No music listened to in this period (or listening is turned off)." }
        var lines = ["\(summary.plays) songs played."]
        lines.append("Moods: " + summary.moods.prefix(6).map { "\($0.0) ×\($0.1)" }.joined(separator: ", "))
        if let v = summary.averageValence, let e = summary.averageEnergy {
            lines.append("Average positivity \(Int(v))/100, energy \(Int(e))/100.")
        }
        lines.append("Top artists: " + summary.topArtists.map { "\($0.0) (\($0.1))" }.joined(separator: ", "))
        if !summary.toneByMood.isEmpty {
            lines.append("Tone of the user's own messages while each mood played (-1 negative … 1 positive): "
                + summary.toneByMood.map { "\($0.0) \(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
        }
        lines.append("Late-night listening (23h–5h): \(Int(summary.lateNightShare * 100))%.")
        return lines.joined(separator: "\n")
    }
}

nonisolated struct MusicMoodTool: Tool {
    let name = "music_mood"
    let description = """
    What the user has been listening to on Spotify or Apple Music, the mood of that music, and how the tone of \
    their messages matched it. Use for "how am I feeling lately?", "what does my music say about me?", or to be \
    gentle when their listening has been sad.
    """

    @Generable
    struct Arguments {
        @Guide(description: "How many days back to look", .range(1...60))
        var days: Int
    }

    @concurrent func call(arguments: Arguments) async throws -> String {
        await CardBus.status(String(localized: "Listening back to your music…"))
        let summary = await MusicMood.summary(days: arguments.days)
        let now = await MainActor.run { MusicListener.shared.nowPlaying }
        var text = MusicMood.describe(summary)
        if let now { text += "\nPlaying right now: \(now.track) by \(now.artist) on \(now.app)." }
        return text
    }
}
#endif
