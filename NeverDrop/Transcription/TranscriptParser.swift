import Foundation
import os
import Sentry

private let logger = Logger.app(category: "TranscriptParser")

enum TranscriptParser {

    private static let speakerHeaderPattern = try! NSRegularExpression(
        pattern: #"^(\[\d{2}:\d{2}\]\s+)?(.+):$"#
    )

    private static let filenameDateFormat: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    static func parse(url: URL) -> TranscriptFile? {
        let filename = url.deletingPathExtension().lastPathComponent
        guard let date = filenameDateFormat.date(from: filename) else {
            logger.warning("Cannot parse date from transcript filename: \(filename)")
            return nil
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Cannot read transcript file: \(url.path)")
            return nil
        }

        let segments = parseContent(content)
        return TranscriptFile(url: url, date: date, segments: segments)
    }

    static func parseContent(_ content: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var currentTimestamp: String?
        var currentSpeaker: String?
        var currentLines: [String] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = matchSpeakerHeader(trimmed) {
                if let speaker = currentSpeaker, !currentLines.isEmpty {
                    let text = currentLines.joined(separator: "\n")
                    segments.append(TranscriptSegment(
                        timestamp: currentTimestamp,
                        speaker: speaker,
                        text: text
                    ))
                }
                currentTimestamp = match.timestamp
                currentSpeaker = match.speaker
                currentLines = []
            } else if trimmed.isEmpty {
                continue
            } else {
                currentLines.append(trimmed)
            }
        }

        if let speaker = currentSpeaker, !currentLines.isEmpty {
            let text = currentLines.joined(separator: "\n")
            segments.append(TranscriptSegment(
                timestamp: currentTimestamp,
                speaker: speaker,
                text: text
            ))
        }

        return segments
    }

    static func serialize(segments: [TranscriptSegment]) -> String {
        var output = ""
        for (index, segment) in segments.enumerated() {
            if index > 0 { output += "\n" }
            if let ts = segment.timestamp {
                output += "\(ts) \(segment.speaker):\n"
            } else {
                output += "\(segment.speaker):\n"
            }
            output += "\(segment.text)\n"
        }
        return output
    }

    // MARK: - Timestamp helpers

    static func parseTimestampSeconds(_ timestamp: String) -> Int? {
        let clean = timestamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = clean.split(separator: ":")
        guard parts.count == 2, let mm = Int(parts[0]), let ss = Int(parts[1]) else { return nil }
        return mm * 60 + ss
    }

    static func formatTimestamp(_ totalSeconds: Int) -> String {
        String(format: "[%02d:%02d]", totalSeconds / 60, totalSeconds % 60)
    }

    // MARK: - Helpers

    private struct HeaderMatch {
        let timestamp: String?
        let speaker: String
    }

    private static func matchSpeakerHeader(_ line: String) -> HeaderMatch? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = speakerHeaderPattern.firstMatch(in: line, range: range) else {
            return nil
        }

        var timestamp: String?
        let tsRange = match.range(at: 1)
        if tsRange.location != NSNotFound, let swiftRange = Range(tsRange, in: line) {
            timestamp = String(line[swiftRange]).trimmingCharacters(in: .whitespaces)
        }

        let speakerRange = match.range(at: 2)
        guard speakerRange.location != NSNotFound, let swiftRange = Range(speakerRange, in: line) else {
            return nil
        }

        return HeaderMatch(timestamp: timestamp, speaker: String(line[swiftRange]))
    }
}
