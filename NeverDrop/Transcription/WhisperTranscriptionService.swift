import Foundation
import Observation
import os
import WhisperKit

private let logger = Logger.app(category: "Transcription")

@MainActor
@Observable
final class WhisperTranscriptionService: TranscriptionService {

    private(set) var isReady = false
    private(set) var isTranscribing = false
    private(set) var currentHypothesis: String = ""
    private(set) var modelLoadingProgress: String = "Loading model..."

    private var whisperKit: WhisperKit?
    private var transcribeTask: Task<Void, Never>?

    private let pollingInterval: Duration = .seconds(2)
    private let maxBufferSeconds: Double = 30
    private let confirmationLag: Float = 4.0
    private let silenceRMSThreshold: Float = 1e-4

    var selectedLanguage: String?

    private var micAccumulated: [Float] = []
    private var micLastConfirmedEnd: Float = 0
    private var systemAccumulated: [Float] = []
    private var systemLastConfirmedEnd: Float = 0
    private var recordingStartDate: Date?
    private var sampleRate: Double = 16_000

    // MARK: - TranscriptionService

    func prepare() async throws {
        modelLoadingProgress = "Downloading model..."
        let config = WhisperKitConfig(model: "base", verbose: false)
        let kit = try await WhisperKit(config)
        whisperKit = kit
        isReady = true
        modelLoadingProgress = "Model ready"
    }

    func startTranscribing(audioSource: any AudioSource, writer: any TranscriptionWriting) {
        guard isReady, !isTranscribing else { return }
        isTranscribing = true
        micAccumulated.removeAll()
        micLastConfirmedEnd = 0
        systemAccumulated.removeAll()
        systemLastConfirmedEnd = 0
        recordingStartDate = Date()
        sampleRate = audioSource.sampleRate

        transcribeTask = Task { [weak self] in
            guard let self else { return }
            await self.transcriptionLoop(audioSource: audioSource, writer: writer)
        }
    }

    func stopTranscribing() {
        isTranscribing = false
        transcribeTask?.cancel()
        transcribeTask = nil
        currentHypothesis = ""
        micAccumulated.removeAll()
        systemAccumulated.removeAll()
    }

    // MARK: - Streaming loop

    private func transcriptionLoop(audioSource: any AudioSource, writer: any TranscriptionWriting) async {
        guard let whisperKit else { return }

        while isTranscribing, !Task.isCancelled {
            do {
                try await Task.sleep(for: pollingInterval)
            } catch { break }

            let newMic = audioSource.drainMicSamples()
            let newSystem = audioSource.drainSystemSamples()
            guard !newMic.isEmpty || !newSystem.isEmpty else { continue }

            micAccumulated.append(contentsOf: newMic)
            systemAccumulated.append(contentsOf: newSystem)

            trimBuffer(&micAccumulated, lastConfirmedEnd: &micLastConfirmedEnd)
            trimBuffer(&systemAccumulated, lastConfirmedEnd: &systemLastConfirmedEnd)

            let micRMS = rmsEnergy(micAccumulated)
            let sysRMS = rmsEnergy(systemAccumulated)
            logger.debug(
                "mic: \(newMic.count) new / \(self.micAccumulated.count) total, rms=\(micRMS, format: .fixed(precision: 6)) | sys: \(newSystem.count) new / \(self.systemAccumulated.count) total, rms=\(sysRMS, format: .fixed(precision: 6))"
            )

            var confirmed: [(speaker: Speaker, text: String, sortKey: TimeInterval)] = []
            var latestHypothesis: String = ""

            if micRMS > silenceRMSThreshold {
                let result = await transcribeStream(
                    samples: micAccumulated, lastConfirmedEnd: micLastConfirmedEnd,
                    speaker: .you, whisperKit: whisperKit
                )
                micLastConfirmedEnd = result.updatedLastConfirmedEnd
                confirmed.append(contentsOf: result.confirmed)
                if !result.hypothesis.isEmpty { latestHypothesis = result.hypothesis }
            }

            if sysRMS > silenceRMSThreshold {
                let result = await transcribeStream(
                    samples: systemAccumulated, lastConfirmedEnd: systemLastConfirmedEnd,
                    speaker: .identified("1"), whisperKit: whisperKit
                )
                systemLastConfirmedEnd = result.updatedLastConfirmedEnd
                confirmed.append(contentsOf: result.confirmed)
                if !result.hypothesis.isEmpty { latestHypothesis = result.hypothesis }
            }

            confirmed.sort { $0.sortKey < $1.sortKey }

            let now = Date()
            for seg in confirmed {
                let relativeTime = recordingStartDate.map { now.timeIntervalSince($0) } ?? 0
                writer.append(text: seg.text, speaker: seg.speaker, relativeTime: relativeTime)
            }
            currentHypothesis = latestHypothesis
        }
    }

    // MARK: - Per-stream transcription

    private struct StreamResult {
        var confirmed: [(speaker: Speaker, text: String, sortKey: TimeInterval)]
        var hypothesis: String
        var updatedLastConfirmedEnd: Float
    }

    private func transcribeStream(
        samples: [Float],
        lastConfirmedEnd: Float,
        speaker: Speaker,
        whisperKit: WhisperKit
    ) async -> StreamResult {
        let lang = selectedLanguage
        let options = DecodingOptions(
            task: .transcribe,
            language: lang,
            detectLanguage: lang == nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            clipTimestamps: [lastConfirmedEnd]
        )

        let results: [TranscriptionResult]
        do {
            results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            return StreamResult(confirmed: [], hypothesis: "", updatedLastConfirmedEnd: lastConfirmedEnd)
        }

        let bufferHeadSeconds = Float(samples.count) / Float(sampleRate)
        let confirmThreshold = bufferHeadSeconds - confirmationLag

        var confirmed: [(speaker: Speaker, text: String, sortKey: TimeInterval)] = []
        var hypothesis = ""
        var newLastConfirmedEnd = lastConfirmedEnd

        for result in results {
            for segment in result.segments {
                let cleanedText = stripSpecialTokens(segment.text)
                guard !cleanedText.isEmpty else { continue }

                if segment.end <= confirmThreshold {
                    confirmed.append((speaker: speaker, text: cleanedText, sortKey: TimeInterval(segment.start)))
                    newLastConfirmedEnd = max(newLastConfirmedEnd, segment.end)
                } else {
                    hypothesis = cleanedText
                }
            }
        }

        return StreamResult(confirmed: confirmed, hypothesis: hypothesis, updatedLastConfirmedEnd: newLastConfirmedEnd)
    }

    // MARK: - Helpers

    private func trimBuffer(_ buffer: inout [Float], lastConfirmedEnd: inout Float) {
        let maxSamples = Int(maxBufferSeconds * sampleRate)
        if buffer.count > maxSamples {
            let excess = buffer.count - maxSamples
            buffer.removeFirst(excess)
            let removedSeconds = Float(excess) / Float(sampleRate)
            lastConfirmedEnd = max(0, lastConfirmedEnd - removedSeconds)
        }
    }

    private func rmsEnergy(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    private static let specialTokenPattern = try! NSRegularExpression(pattern: #"<\|[^|]*\|>"#)
    private static let hallucination = try! NSRegularExpression(
        pattern: #"^\s*[\[\(]?\s*(silence|pause|blank[_ ]?audio|background\s*sounds?|beep|music|applause|laughter)\s*[\]\)]?\s*$"#,
        options: .caseInsensitive
    )

    private func stripSpecialTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let cleaned = Self.specialTokenPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRange = NSRange(trimmed.startIndex..., in: trimmed)
        if Self.hallucination.firstMatch(in: trimmed, range: trimmedRange) != nil { return "" }
        return trimmed
    }
}
