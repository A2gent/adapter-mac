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
    var count: Int { requests.count }
    var isEmpty: Bool { requests.isEmpty }

    mutating func enqueue(_ request: VoiceDecodeRequest) throws {
        if let index = requests.lastIndex(where: { $0.id == request.id && !$0.isFinal }) {
            requests[index] = request
        } else {
            guard requests.count < 4 else {
                throw SessionServiceError.message("Local recognition cannot keep up. Your command was not sent.")
            }
            requests.append(request)
        }
    }

    mutating func popFirst() -> VoiceDecodeRequest? {
        requests.isEmpty ? nil : requests.removeFirst()
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

    mutating func append(_ chunk: [Float], speech: Bool, speechTime: TimeInterval) -> VoiceDecodeRequest? {
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
        let partial = hasUtterance && samples.count - lastDecodedSize >= 12_000
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
