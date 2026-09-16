import Foundation

enum VoiceModelLoadState: Equatable, Sendable {
    case idle
    case loading(String, Double?)
    case ready
    case cancelled
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var canRetry: Bool {
        switch self {
        case .cancelled, .failed: return true
        case .idle, .loading, .ready: return false
        }
    }

    var progress: Double? {
        if case .loading(_, let value) = self { return value }
        return nil
    }

    var message: String {
        switch self {
        case .idle, .ready, .cancelled: return ""
        case .loading(let text, _), .failed(let text): return text
        }
    }
}

struct VoiceSettings: Codable, Equatable, Sendable {
    var enabled = false
    var agentName = "Brute"
    var newSessionPhrases = "new session, start new session"
    var endPhrases = "over, end command"
    var silenceSeconds: Double = 1.5
    var silenceTimingVersion: Int? = 1
    var speakReplies = true
    var localeIdentifier = "en-US"

    var validationMessage: String? {
        guard !VoiceCommandState.words(agentName).isEmpty else { return "Enter an agent name." }
        guard agentName.count <= 80, newSessionPhrases.count <= 300, endPhrases.count <= 300 else {
            return "Voice phrases are too long."
        }
        guard ["ru-RU", "en-US"].contains(localeIdentifier) else { return "Choose a supported voice language." }
        guard !newSessionPhraseList.isEmpty else { return "Enter at least one new session phrase." }
        guard !endPhraseList.isEmpty else { return "Enter at least one end phrase." }
        guard silenceSeconds.isFinite, (0.5...30).contains(silenceSeconds) else {
            return "Silence must be 0.5–30 seconds."
        }
        return nil
    }

    var newSessionPhraseList: [String] { Self.phraseList(newSessionPhrases) }
    var endPhraseList: [String] { Self.phraseList(endPhrases) }

    private static func phraseList(_ value: String) -> [String] {
        value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !VoiceCommandState.words($0).isEmpty }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "voiceConversationSettings"),
            var value = try? JSONDecoder().decode(Self.self, from: data), value.validationMessage == nil
        else { return Self() }
        // The old 10-second default made every command feel stalled. Keep custom delays,
        // and version new saves so explicitly choosing 10 seconds remains possible.
        if value.silenceTimingVersion == nil {
            if value.silenceSeconds == 10 { value.silenceSeconds = 1.5 }
            value.silenceTimingVersion = 1
            value.save(to: defaults)
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        guard validationMessage == nil, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "voiceConversationSettings")
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, agentName, newSessionPhrases, endPhrases, silenceSeconds, silenceTimingVersion, speakReplies
        case localeIdentifier
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        agentName = try values.decodeIfPresent(String.self, forKey: .agentName) ?? "Brute"
        // Older settings relied on this hard-coded phrase, so preserve it during migration.
        newSessionPhrases = try values.decodeIfPresent(String.self, forKey: .newSessionPhrases) ?? "новая сессия"
        endPhrases = try values.decodeIfPresent(String.self, forKey: .endPhrases) ?? "приём, конец команды"
        silenceSeconds = try values.decodeIfPresent(Double.self, forKey: .silenceSeconds) ?? 1.5
        silenceTimingVersion = try values.decodeIfPresent(Int.self, forKey: .silenceTimingVersion)
        speakReplies = try values.decodeIfPresent(Bool.self, forKey: .speakReplies) ?? true
        localeIdentifier = try values.decodeIfPresent(String.self, forKey: .localeIdentifier) ?? "ru-RU"
    }
}

enum VoiceCommandEvent: Equatable {
    case activated
    case submit(String, newSession: Bool)
    case newSession
    case cancelled
    case limitReached
}

/// Works on revisable STT hypotheses, not appended deltas. Only activated speech survives a segment rollover.
struct VoiceCommandState {
    let settings: VoiceSettings
    private(set) var listening = false
    private(set) var text = ""
    private var committed = ""
    private var segmentHasWake = false
    private var started: TimeInterval = 0
    private var lastSpeech: TimeInterval = 0
    private var previousHypothesis = ""

    init(settings: VoiceSettings) { self.settings = settings }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    // Preserve spelling/punctuation in the actual message while matching normalized whole words.
    private static func tokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return (words(String(text[range])).joined(), range)
        }
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    mutating func receive(_ hypothesis: String, now: TimeInterval, speechTime: TimeInterval? = nil)
        -> [VoiceCommandEvent]
    {
        let heardAt = speechTime ?? now
        let hypothesis = String(hypothesis.prefix(12_000))
        let tokens = Self.tokens(hypothesis)
        let wake = Self.words(settings.agentName)
        var events: [VoiceCommandEvent] = []
        var body = hypothesis
        if !listening || segmentHasWake {
            guard !wake.isEmpty, tokens.count >= wake.count,
                let index = (0...(tokens.count - wake.count)).first(where: {
                    Array(tokens[$0..<($0 + wake.count)].map(\.word)) == wake
                })
            else { return [] }
            body = String(hypothesis[tokens[index + wake.count - 1].range.upperBound...])
            if !listening {
                reset()
                listening = true
                started = now
                lastSpeech = heardAt
                events.append(.activated)
            }
            segmentHasWake = true
        }
        guard listening else { return events }
        if hypothesis != previousHypothesis { lastSpeech = max(lastSpeech, heardAt) }
        previousHypothesis = hypothesis
        text = Self.trim([committed, Self.trim(body)].filter { !$0.isEmpty }.joined(separator: " "))
        if text.count > 8_000 {
            text = String(text.prefix(8_000))
            listening = false
            return events + [.limitReached]
        }
        if Self.words(text) == ["отмена"] || Self.words(text) == ["cancel"] {
            reset()
            return events + [.cancelled]
        }
        for phrase in settings.endPhraseList.sorted(by: { Self.words($0).count > Self.words($1).count }) {
            let ending = Self.words(phrase)
            let all = Self.tokens(text)
            if all.count >= ending.count, Array(all.suffix(ending.count).map(\.word)) == ending {
                text = Self.trim(String(text[..<all[all.count - ending.count].range.lowerBound]))
                return events + finish()
            }
        }
        return events
    }

    mutating func speechDetected(now: TimeInterval) {
        if listening { lastSpeech = now }
    }

    mutating func tick(now: TimeInterval) -> [VoiceCommandEvent] {
        guard listening else { return [] }
        if now - started >= 120 {
            listening = false
            return [.limitReached]
        }
        return now - lastSpeech >= settings.silenceSeconds ? finish() : []
    }

    mutating func finishSegment() {
        committed = listening ? text : ""
        segmentHasWake = false
        previousHypothesis = ""
    }

    mutating func finish() -> [VoiceCommandEvent] {
        var command = Self.trim(text)
        let tokens = Self.tokens(command)
        var newSession = false
        let phrases = settings.newSessionPhraseList.sorted {
            Self.words($0).count > Self.words($1).count
        }
        for phrase in phrases {
            let opening = Self.words(phrase)
            guard tokens.count >= opening.count,
                Array(tokens.prefix(opening.count).map(\.word)) == opening
            else { continue }
            command = Self.trim(String(command[tokens[opening.count - 1].range.upperBound...]))
            newSession = true
            break
        }
        reset()
        if command.isEmpty { return [newSession ? .newSession : .cancelled] }
        return [.submit(command, newSession: newSession)]
    }
    mutating func reset() {
        listening = false
        text = ""
        committed = ""
        segmentHasWake = false
        previousHypothesis = ""
    }
}
