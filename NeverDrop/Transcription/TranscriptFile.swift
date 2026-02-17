import Foundation

struct TranscriptFile: Identifiable {
    var id: URL { url }
    let url: URL
    let date: Date
    var customName: String?
    var segments: [TranscriptSegment]

    var displayName: String {
        customName ?? dateString
    }

    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
