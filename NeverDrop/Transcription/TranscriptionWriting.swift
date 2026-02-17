import Foundation

protocol TranscriptionWriting {
    func append(text: String, speaker: Speaker, relativeTime: TimeInterval)
}
