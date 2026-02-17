import Foundation
import Observation
import os

private let logger = Logger.app(category: "TranscriptStore")

@Observable
final class TranscriptStore {

    var files: [TranscriptFile] = []
    var selectedFileURLs: Set<URL> = []

    var selectedFile: TranscriptFile? {
        guard selectedFileURLs.count == 1, let url = selectedFileURLs.first else { return nil }
        return files.first { $0.url == url }
    }

    private let directoryPath: String

    init(directoryPath: String = TranscriptWriter.transcriptsDirectoryPath) {
        self.directoryPath = directoryPath
    }

    // MARK: - Loading

    func loadFiles() {
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let fm = FileManager.default

        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            files = []
            return
        }

        let txtFiles = urls.filter { $0.pathExtension == "txt" }
        files = txtFiles.compactMap { url -> TranscriptFile? in
            guard var file = TranscriptParser.parse(url: url) else { return nil }
            file.customName = loadCustomName(for: url)
            return file
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: - Speaker rename

    func renameSpeaker(fileURL: URL, segmentID: UUID, newName: String) {
        guard let fileIndex = files.firstIndex(where: { $0.url == fileURL }),
              let segIndex = files[fileIndex].segments.firstIndex(where: { $0.id == segmentID })
        else { return }

        files[fileIndex].segments[segIndex].speaker = newName
        saveTranscript(files[fileIndex])
    }

    func renameAllOccurrences(fileURL: URL, oldName: String, newName: String) {
        guard let fileIndex = files.firstIndex(where: { $0.url == fileURL }) else { return }

        for i in files[fileIndex].segments.indices {
            if files[fileIndex].segments[i].speaker == oldName {
                files[fileIndex].segments[i].speaker = newName
            }
        }
        saveTranscript(files[fileIndex])
    }

    // MARK: - Conversation rename

    func renameConversation(fileURL: URL, newName: String) {
        guard let fileIndex = files.firstIndex(where: { $0.url == fileURL }) else { return }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        files[fileIndex].customName = trimmed.isEmpty ? nil : trimmed
        saveCustomName(for: fileURL, name: files[fileIndex].customName)
    }

    // MARK: - Delete

    func deleteFiles(urls: Set<URL>) {
        let fm = FileManager.default
        for url in urls {
            do {
                try fm.removeItem(at: url)
                let metaURL = metaURL(for: url)
                if fm.fileExists(atPath: metaURL.path) {
                    try fm.removeItem(at: metaURL)
                }
            } catch {
                logger.error("Failed to delete transcript \(url.lastPathComponent): \(error)")
            }
        }
        files.removeAll { urls.contains($0.url) }
        selectedFileURLs.subtract(urls)
    }

    // MARK: - Copy

    func fullText(for file: TranscriptFile) -> String {
        TranscriptParser.serialize(segments: file.segments)
    }

    // MARK: - Persistence

    private func saveTranscript(_ file: TranscriptFile) {
        let content = TranscriptParser.serialize(segments: file.segments)
        do {
            try content.write(to: file.url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save transcript file \(file.url.path): \(error)")
        }
    }

    private func metaURL(for transcriptURL: URL) -> URL {
        transcriptURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    private func loadCustomName(for transcriptURL: URL) -> String? {
        let url = metaURL(for: transcriptURL)
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(TranscriptMeta.self, from: data)
        else { return nil }
        return meta.name
    }

    private func saveCustomName(for transcriptURL: URL, name: String?) {
        let url = metaURL(for: transcriptURL)
        if let name {
            let meta = TranscriptMeta(name: name)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: url, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private struct TranscriptMeta: Codable {
    let name: String
}
