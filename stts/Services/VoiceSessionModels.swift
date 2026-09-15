import Foundation

struct VoiceChatReply: Decodable, Sendable {
    let content: String
    let status: String
}

struct VoiceSessionSnapshot: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let role: String
        let content: String
    }
    let id: String
    let status: String
    let messages: [Message]?

    var finished: Bool { ["completed", "failed", "paused", "input_required"].contains(status) }
    var reply: String {
        let messages = messages ?? []
        let start = messages.lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
        return messages.dropFirst(start).last(where: { $0.role == "assistant" })?.content ?? ""
    }
}
