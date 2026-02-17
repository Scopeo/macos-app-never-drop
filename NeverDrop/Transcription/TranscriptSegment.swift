import Foundation

struct TranscriptSegment: Identifiable {
    let id: UUID
    var timestamp: String?
    var speaker: String
    var text: String

    init(id: UUID = UUID(), timestamp: String? = nil, speaker: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
    }
}
