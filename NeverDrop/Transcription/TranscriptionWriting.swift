import Foundation

protocol TranscriptionWriting {
    func append(text: String, timestamp: TimeInterval, speaker: Speaker)
}
