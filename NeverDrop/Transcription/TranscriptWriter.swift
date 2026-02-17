import Foundation
import os

private let logger = Logger.app(category: "TranscriptWriter")

final class TranscriptWriter: TranscriptionWriting {

    static let transcriptsDirectoryPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("com.draftnrun.NeverDrop/Transcripts").path
    }()

    var userName: String = ""

    private let directoryURL: URL
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var lastSpeaker: Speaker?

    init(directoryPath: String = TranscriptWriter.transcriptsDirectoryPath) {
        self.directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    }

    // MARK: - Lifecycle

    func open() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "\(formatter.string(from: Date())).txt"
        let fileURL = directoryURL.appendingPathComponent(filename)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        self.fileHandle = handle
        self.currentFileURL = fileURL
        self.lastSpeaker = nil
    }

    func close() {
        do {
            try fileHandle?.close()
        } catch {
            logger.error("Failed to close transcript file: \(error)")
        }
        fileHandle = nil
        currentFileURL = nil
        lastSpeaker = nil
    }

    // MARK: - TranscriptionWriting

    func append(text: String, speaker: Speaker, relativeTime: TimeInterval) {
        guard let handle = fileHandle else { return }

        var output = ""

        if speaker != lastSpeaker {
            if lastSpeaker != nil { output += "\n" }
            let minutes = Int(relativeTime) / 60
            let seconds = Int(relativeTime) % 60
            let timestamp = String(format: "[%02d:%02d]", minutes, seconds)
            output += "\(timestamp) \(speaker.label(userName: userName)):\n"
            lastSpeaker = speaker
        }

        output += "\(text)\n"

        guard let data = output.data(using: .utf8) else { return }
        handle.write(data)
        handle.synchronizeFile()
    }
}
