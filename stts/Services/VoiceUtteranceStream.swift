import Foundation

struct VoiceDecodeRequest: Sendable {
    let id: UUID
    let samples: [Float]
    let isFinal: Bool
    let speechTime: TimeInterval
}

/// Keep final segments in order, but never make a slow decoder replay obsolete partial hypotheses.
struct VoiceDecodeQueue {
    private var requests: [VoiceDecodeRequest] = []
    // A pause must not cost the same budget as a 15-second segment. Bound retained PCM
    // (~1.9 MB at 30 seconds), not the number of short utterances in a burst.
    let maxSamples: Int
    private(set) var queuedSampleCount = 0
    var count: Int { requests.count }
    var isEmpty: Bool { requests.isEmpty }

    init(maxSamples: Int = 16_000 * 30) { self.maxSamples = maxSamples }

    mutating func enqueue(_ request: VoiceDecodeRequest) throws {
        guard !request.samples.isEmpty else { return }
        let index = requests.lastIndex(where: { $0.id == request.id && !$0.isFinal })
        let replacedCount = index.map { requests[$0].samples.count } ?? 0
        let updatedCount = queuedSampleCount - replacedCount + request.samples.count
        guard updatedCount <= maxSamples else {
            throw SessionServiceError.message(
                "The recognition backlog exceeded 30 seconds of audio. Capture paused to avoid sending an incomplete command. Use the Release scheme in Xcode, then Retry in Voice settings."
            )
        }
        if let index {
            requests[index] = request
        } else {
            requests.append(request)
        }
        queuedSampleCount = updatedCount
    }

    mutating func popFirst() -> VoiceDecodeRequest? {
        guard !requests.isEmpty else { return nil }
        let request = requests.removeFirst()
        queuedSampleCount -= request.samples.count
        return request
    }
}

struct VoiceUtteranceStream {
    private var preRoll: [Float] = []
    private var samples: [Float] = []
    private var silenceChunks = 0
    private var lastDecodedSize = 0
    private var lastSpeech: TimeInterval = 0
    private var id = UUID()
    var hasUtterance: Bool { !samples.isEmpty }

    mutating func append(
        _ chunk: [Float], speech: Bool, speechTime: TimeInterval, allowPartial: Bool = true
    ) -> VoiceDecodeRequest? {
        if speech {
            if samples.isEmpty { samples = preRoll }
            lastSpeech = speechTime
            silenceChunks = 0
        } else {
            silenceChunks += 1
        }
        preRoll = Array((preRoll + chunk).suffix(8192))
        if speech || hasUtterance { samples.append(contentsOf: chunk) }
        let final = hasUtterance && (silenceChunks >= 3 || samples.count >= 16_000 * 15)
        let partial = allowPartial && hasUtterance && samples.count - lastDecodedSize >= 12_000
        guard final || partial else { return nil }
        let request = VoiceDecodeRequest(id: id, samples: samples, isFinal: final, speechTime: lastSpeech)
        lastDecodedSize = samples.count
        if final {
            samples.removeAll(keepingCapacity: true)
            preRoll.removeAll(keepingCapacity: true)
            lastDecodedSize = 0
            id = UUID()
        }
        return request
    }
}
