import AVFoundation
import Foundation
import Observation
import os

private let logger = Logger.app(category: "OpenAI")

@MainActor
@Observable
final class OpenAITranscriptionService: TranscriptionService {

    private(set) var isReady = false

    var selectedLanguage: String?

    private let apiKey: String
    private var transcribeTask: Task<Void, Never>?
    private var isTranscribing = false
    private var speakerMapping: [String: String] = [:]
    private var nextSpeakerNumber = 1
    private var recordingStartDate: Date?

    private static let transcriptionURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let pollingInterval: Duration = .seconds(5)
    private static let minChunkSeconds: Double = 2.0

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - TranscriptionService

    func prepare() async throws {
        isReady = !apiKey.isEmpty
        if !isReady {
            logger.info("OpenAI API key not set — service not ready")
        }
    }

    func startTranscribing(audioSource: any AudioSource, writer: any TranscriptionWriting) {
        guard isReady, !isTranscribing else { return }
        isTranscribing = true
        speakerMapping = [:]
        nextSpeakerNumber = 1
        recordingStartDate = Date()

        transcribeTask = Task { [weak self] in
            guard let self else { return }
            await self.transcriptionLoop(audioSource: audioSource, writer: writer)
        }
    }

    func stopTranscribing() {
        guard isTranscribing else { return }
        isTranscribing = false
        transcribeTask?.cancel()
        transcribeTask = nil
    }

    // MARK: - Transcription loop

    private func transcriptionLoop(audioSource: any AudioSource, writer: any TranscriptionWriting) async {
        let sampleRate = audioSource.sampleRate
        var micAccumulated: [Float] = []
        var systemAccumulated: [Float] = []

        while isTranscribing, !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.pollingInterval)
            } catch { break }

            let mic = audioSource.drainMicSamples()
            let system = audioSource.drainSystemSamples()
            micAccumulated.append(contentsOf: mic)
            systemAccumulated.append(contentsOf: system)

            let micSeconds = Double(micAccumulated.count) / sampleRate
            let systemSeconds = Double(systemAccumulated.count) / sampleRate
            guard micSeconds >= Self.minChunkSeconds || systemSeconds >= Self.minChunkSeconds else { continue }

            let micWav = micSeconds >= Self.minChunkSeconds
                ? createWAV(samples: micAccumulated, sampleRate: Int(sampleRate))
                : nil
            let systemWav = systemSeconds >= Self.minChunkSeconds
                ? createWAV(samples: systemAccumulated, sampleRate: Int(sampleRate))
                : nil

            if micWav != nil { micAccumulated.removeAll(keepingCapacity: true) }
            if systemWav != nil { systemAccumulated.removeAll(keepingCapacity: true) }

            do {
                async let micResult = transcribeMic(wavData: micWav)
                async let systemResult = transcribeSystem(wavData: systemWav)

                let micText = try await micResult
                let systemSegments = try await systemResult

                let relativeTime = self.recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
                if let text = micText, !text.isEmpty {
                    writer.append(text: text, speaker: .you, relativeTime: relativeTime)
                }
                for segment in systemSegments {
                    let mappedID = mapSpeaker(segment.speaker)
                    writer.append(text: segment.text, speaker: .identified(mappedID), relativeTime: relativeTime)
                }
            } catch {
                logger.error("OpenAI transcription request failed: \(error)")
            }
        }
    }

    // MARK: - Mic transcription (simple, no diarization)

    private func transcribeMic(wavData: Data?) async throws -> String? {
        guard let wavData else { return nil }

        let boundary = UUID().uuidString
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"mic.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        appendField("model", "gpt-4o-mini-transcribe")
        appendField("response_format", "json")
        if let lang = selectedLanguage {
            appendField("language", lang)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Self.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.unexpectedResponse("Non-HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw OpenAIError.apiError(httpResponse.statusCode, errorBody)
        }

        let decoded = try JSONDecoder().decode(SimpleTranscriptionResponse.self, from: data)
        return decoded.text
    }

    // MARK: - System transcription (diarized)

    private func transcribeSystem(wavData: Data?) async throws -> [DiarizedSegment] {
        guard let wavData else { return [] }

        let boundary = UUID().uuidString
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"system.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        appendField("model", "gpt-4o-transcribe-diarize")
        appendField("response_format", "diarized_json")
        if let lang = selectedLanguage {
            appendField("language", lang)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Self.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.unexpectedResponse("Non-HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw OpenAIError.apiError(httpResponse.statusCode, errorBody)
        }

        let decoded = try JSONDecoder().decode(DiarizedResponse.self, from: data)
        return decoded.segments ?? []
    }

    // MARK: - Speaker mapping

    private func mapSpeaker(_ apiID: String) -> String {
        if let mapped = speakerMapping[apiID] { return mapped }
        let number = String(nextSpeakerNumber)
        speakerMapping[apiID] = number
        nextSpeakerNumber += 1
        return number
    }

    // MARK: - WAV encoding

    private func createWAV(samples: [Float], sampleRate: Int) -> Data {
        let pcm = floatToPCMS16LE(samples)
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let chunkSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(littleEndian: chunkSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(littleEndian: UInt32(16))               // subchunk1 size
        header.append(littleEndian: UInt16(1))                // PCM format
        header.append(littleEndian: numChannels)
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(littleEndian: dataSize)
        header.append(pcm)

        return header
    }

    // MARK: - Audio helpers

    private func floatToPCMS16LE(_ samples: [Float]) -> Data {
        AudioEncoding.floatToPCMS16LE(samples)
    }
}

// MARK: - Data helper for WAV encoding

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

// MARK: - Response types

private struct SimpleTranscriptionResponse: Decodable {
    let text: String
}

private struct DiarizedResponse: Decodable {
    let text: String?
    let segments: [DiarizedSegment]?
}

private struct DiarizedSegment: Decodable {
    let speaker: String
    let text: String
    let start: Double?
    let end: Double?
}

// MARK: - Errors

enum OpenAIError: Error, CustomStringConvertible {
    case missingAPIKey
    case unexpectedResponse(String)
    case apiError(Int, String)

    var description: String {
        switch self {
        case .missingAPIKey: "OpenAI API key is not configured"
        case .unexpectedResponse(let msg): "Unexpected response: \(msg)"
        case .apiError(let code, let body): "OpenAI API error \(code): \(body)"
        }
    }
}
