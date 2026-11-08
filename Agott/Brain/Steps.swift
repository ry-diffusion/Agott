import Foundation
import FoundationModels

/// One visible piece of work behind a reply: a stretch of thinking, a look at
/// the screen, a memory search, a tool call.
nonisolated struct Step: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case thinking, context, tool }
    enum State: String, Codable, Sendable { case running, done, failed }

    var id: String
    var kind: Kind
    var title: String
    var symbol: String
    var state: State
    /// Reasoning text, or what a tool returned. Shown when expanded.
    var detail: String?
    var started: Date
    var ended: Date?
    /// What the step found, when it found things: remembered moments, chats.
    var items: [Item]?

    nonisolated struct Item: Codable, Hashable, Sendable, Identifiable {
        var id: String { title + "|" + (subtitle ?? "") + "|" + (snippet ?? "") }
        var title: String
        var subtitle: String?
        var snippet: String?
        var symbol: String = "text.bubble"
    }

    init(id: String, kind: Kind, title: String, symbol: String, state: State, detail: String? = nil,
         started: Date, ended: Date? = nil, items: [Item]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.state = state
        self.detail = detail
        self.started = started
        self.ended = ended
        self.items = items
    }

    var seconds: Int? {
        guard let ended else { return nil }
        return max(1, Int(ended.timeIntervalSince(started).rounded()))
    }
}

/// Reads the session transcript and turns it into steps people can follow.
///
/// The transcript already records everything the model did: reasoning,
/// each tool call with its arguments, each tool's output. So the steps are
/// derived from it rather than reported by each tool, which means every tool,
/// present and future, shows up without extra code.
enum StepTracker {
    /// First-seen and finished times, by step id, so durations survive the
    /// steps being rebuilt on every poll.
    final class Clock {
        var started: [String: Date] = [:]
        var ended: [String: Date] = [:]

        func start(_ id: String) -> Date {
            if let date = started[id] { return date }
            let now = Date()
            started[id] = now
            return now
        }

        func end(_ id: String) -> Date {
            if let date = ended[id] { return date }
            let now = Date()
            ended[id] = now
            return now
        }
    }

    /// Steps for the entries after `baseline`. `busy` adds a running
    /// "Thinking" step whenever the model is working with nothing to show.
    static func steps(from transcript: Transcript, after baseline: Int, busy: Bool, clock: Clock) -> [Step] {
        let entries = Array(transcript.dropFirst(baseline))
        var steps: [Step] = []
        var outputs: [String: String] = [:]
        for entry in entries {
            if case .toolOutput(let output) = entry { outputs[output.id] = text(output.segments) }
        }

        for (index, entry) in entries.enumerated() {
            let isLast = index == entries.count - 1
            switch entry {
            case .reasoning(let reasoning):
                let running = busy && isLast
                let started = clock.start(reasoning.id)
                let thought = text(reasoning.segments)
                steps.append(Step(
                    id: reasoning.id, kind: .thinking,
                    // While it thinks, the latest thing it is thinking about.
                    title: (running ? gist(of: thought) : nil) ?? String(localized: "Thinking"), symbol: "brain",
                    state: running ? .running : .done, detail: thought,
                    started: started, ended: running ? nil : clock.end(reasoning.id)))
            case .toolCalls(let calls):
                for call in calls {
                    let (title, symbol) = describe(call.toolName, arguments: call.arguments.jsonString)
                    let output = outputs[call.id]
                    let running = output == nil && busy
                    let started = clock.start(call.id)
                    let found = output.map(items(in:)) ?? []
                    steps.append(Step(
                        id: call.id, kind: .tool, title: title, symbol: symbol,
                        state: running ? .running : (output?.hasPrefix("The user declined") == true ? .failed : .done),
                        detail: found.isEmpty ? output.map { String($0.prefix(600)) } : nil,
                        started: started, ended: running ? nil : clock.end(call.id),
                        items: found.isEmpty ? nil : found))
                }
            default:
                continue
            }
        }

        // The model is working and has nothing visible yet: say so.
        if busy, let last = entries.last {
            let waiting: Bool = switch last {
            case .prompt, .toolOutput: true
            case .response(let response): text(response.segments).isEmpty
            default: false
            }
            if waiting {
                let id = "thinking-after-\(last.id)"
                steps.append(Step(
                    id: id, kind: .thinking, title: String(localized: "Thinking"), symbol: "brain",
                    state: .running, detail: nil, started: clock.start(id), ended: nil))
            }
        } else if busy && entries.isEmpty {
            let id = "thinking-start"
            steps.append(Step(
                id: id, kind: .thinking, title: String(localized: "Thinking"), symbol: "brain",
                state: .running, detail: nil, started: clock.start(id), ended: nil))
        }
        return steps
    }

    /// A few words for what the model is thinking about now: the latest
    /// heading of its reasoning ("**Checking the calendar**"), or else the
    /// start of its latest sentence. Nil while there is nothing readable yet.
    static func gist(of thought: String) -> String? {
        let text = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Reasoning summaries open each part with a bold heading.
        if let heading = text.matches(of: /\*\*([^*\n]{3,80})\*\*/).last.map({ String($0.1) }) {
            return heading.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        }
        // Otherwise the last finished sentence (the one being written is
        // still changing every frame), shortened.
        let sentences = text.split(whereSeparator: { ".!?\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 8 }
        let finished = text.last.map { ".!?\n".contains($0) } == true ? sentences.last : sentences.dropLast().last
        guard let line = finished ?? sentences.last else { return nil }
        let words = line.split(separator: " ")
        let short = words.prefix(9).joined(separator: " ")
        return words.count > 9 ? short + "…" : short
    }

    /// Memory results come back as "### Source · Chat · date" sections; each
    /// becomes an item you can scan instead of a wall of text.
    static func items(in output: String) -> [Step.Item] {
        output.components(separatedBy: "\n### ").enumerated().compactMap { index, section -> Step.Item? in
            var section = Substring(section)
            if index == 0 {
                guard section.hasPrefix("### ") else { return nil }
                section = section.dropFirst(4)
            }
            let lines = section.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let header = lines.first.map(String.init)?.components(separatedBy: " · ") ?? []
            guard header.count >= 2 else { return nil }
            let body = lines.count > 1 ? String(lines[1]) : ""
            let snippet = body.split(separator: "\n").prefix(3).joined(separator: "\n")
            return Step.Item(
                title: header[1], subtitle: ([header[0]] + header.dropFirst(2)).joined(separator: " · "),
                snippet: snippet.isEmpty ? nil : String(snippet.prefix(220)),
                symbol: symbol(forSource: header[0]))
        }
    }

    static func symbol(forSource name: String) -> String {
        MemorySource.allCases.first { $0.displayName == name }?.symbol ?? "text.bubble"
    }

    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }.joined(separator: "\n")
    }

    /// A tool call in words, with the argument that says what it is about.
    static func describe(_ tool: String, arguments json: String) -> (String, String) {
        let args = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        func arg(_ key: String) -> String { (args[key] as? String).map { String($0.prefix(60)) } ?? "" }
        switch tool {
        case "search_memory": return (String(localized: "Remembering “\(arg("query"))”"), "brain.head.profile")
        case "read_chat": return (String(localized: "Reading your chat with \(arg("person"))"), "text.bubble")
        case "person_insight": return (String(localized: "Looking at you and \(arg("person"))"), "person.2")
        case "people_overview": return (String(localized: "Checking on everyone"), "person.3")
        case "show_relationship": return (String(localized: "Reading your story with \(arg("person"))"), "heart.text.square")
        case "people_circles": return (String(localized: "Looking at your circles"), "circle.grid.2x2")
        case "face_to_face_check": return (String(localized: "Comparing what you say to and about \(arg("person"))"), "theatermasks")
        case "remember": return (String(localized: "Saving to memory"), "pin")
        case "look_at_screen": return (String(localized: "Looking at your screen"), "eye")
        case "press": return (String(localized: "Pressing a button"), "cursorarrow.click")
        case "click_at": return (String(localized: "Clicking"), "cursorarrow.click.2")
        case "type_text": return (String(localized: "Typing"), "keyboard")
        case "press_keys": return (String(localized: "Pressing \(arg("keys"))"), "command")
        case "scroll": return (String(localized: "Scrolling"), "scroll")
        case "open": return (String(localized: "Opening \(arg("target"))"), "arrow.up.forward.app")
        case "run_applescript": return (String(localized: "Running a script"), "applescript")
        case "scriptable_apps": return (String(localized: "Checking which apps I can control"), "app.badge.checkmark")
        case "calendar": return (String(localized: "Checking your calendar"), "calendar")
        case "create_event": return (String(localized: "Adding an event"), "calendar.badge.plus")
        case "tasks": return (String(localized: "Checking your tasks"), "checklist")
        case "create_task": return (String(localized: "Adding a task"), "plus.circle")
        case "complete_task": return (String(localized: "Completing a task"), "checkmark.circle")
        case "read_mail": return (String(localized: "Reading your inbox"), "tray")
        case "draft_email": return (String(localized: "Drafting an email"), "envelope")
        case "show_explanation": return (String(localized: "Writing an explanation"), "lightbulb")
        case "suggest_replies": return (String(localized: "Drafting replies"), "bubble.left.and.text.bubble.right")
        case "show_checklist": return (String(localized: "Making a checklist"), "checklist")
        case "show_chart": return (String(localized: "Drawing a chart"), "chart.bar.xaxis")
        case "artifact": return (String(localized: "Writing “\(arg("title"))”"), "doc.richtext")
        case "music_mood": return (String(localized: "Listening back to your music"), "music.note")
        case "web_search": return (String(localized: "Searching the web for “\(arg("query"))”"), "magnifyingglass")
        case "read_web_page": return (String(localized: "Reading \(URL(string: arg("url"))?.host() ?? arg("url"))"), "safari")
        case "find_place": return (String(localized: "Finding \(arg("query")) on the map"), "map")
        case "nearby_places": return (String(localized: "Looking for \(arg("kind")) near \(arg("near"))"), "mappin.and.ellipse")
        case "movie_info": return (String(localized: "Looking up \(arg("title")) on IMDb"), "film")
        case "where_am_i": return (String(localized: "Checking where you are"), "location")
        case "apple_maps_search": return (String(localized: "Searching Maps for \(arg("query"))"), "map")
        case "travel_time": return (String(localized: "Working out the way to \(arg("to"))"), "car")
        case "translate": return (String(localized: "Translating"), "character.bubble")
        case "remind_me": return (String(localized: "Setting a reminder"), "bell")
        case "contact_info": return (String(localized: "Looking up \(arg("name")) in Contacts"), "person.crop.circle")
        default: return (tool.replacingOccurrences(of: "_", with: " "), "wrench.and.screwdriver")
        }
    }
}
