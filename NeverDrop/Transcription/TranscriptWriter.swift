import Foundation

final class TranscriptWriter: TranscriptionWriting {

    static let transcriptsDirectoryPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("com.draftnrun.NeverDrop/Transcripts").path
    }()

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
        try? fileHandle?.close()
        fileHandle = nil
        currentFileURL = nil
        lastSpeaker = nil
    }

    // MARK: - TranscriptionWriting

    func append(text: String, timestamp: TimeInterval, speaker: Speaker) {
        guard let handle = fileHandle else { return }

        var output = ""

        if speaker != lastSpeaker {
            if lastSpeaker != nil { output += "\n" }
            output += "\(speaker.rawValue):\n"
            lastSpeaker = speaker
        }

        let minutes = Int(timestamp) / 60
        let seconds = Int(timestamp) % 60
        output += "[\(String(format: "%02d:%02d", minutes, seconds))] \(text)\n"

        guard let data = output.data(using: .utf8) else { return }
        handle.write(data)
        handle.synchronizeFile()
    }
}
