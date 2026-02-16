import Foundation
import Observation
import os

private let logger = Logger.app(category: "Soniox")

@MainActor
@Observable
final class SonioxTranscriptionService: TranscriptionService {

    private(set) var isReady = false

    var selectedLanguage: String?

    private let apiKey: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var isTranscribing = false
    private var writer: (any TranscriptionWriting)?
    private var pendingUtterance = ""
    private var pendingUtteranceSpeaker: String?

    private static let sonioxURL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    private static let pollingInterval: Duration = .milliseconds(120)

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - TranscriptionService

    func prepare() async throws {
        isReady = !apiKey.isEmpty
        if !isReady {
            logger.info("Soniox API key not set — service not ready")
        }
    }

    func startTranscribing(audioSource: any AudioSource, writer: any TranscriptionWriting) {
        guard isReady, !isTranscribing else { return }
        isTranscribing = true
        self.writer = writer
        pendingUtterance = ""
        pendingUtteranceSpeaker = nil

        let task = URLSession.shared.webSocketTask(with: Self.sonioxURL)
        webSocketTask = task
        task.resume()

        let config = buildConfig(sampleRate: Int(audioSource.sampleRate))
        let configMessage = URLSessionWebSocketTask.Message.string(config)

        sendTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await task.send(configMessage)
            } catch {
                logger.error("Failed to send Soniox config: \(error)")
                return
            }

            await self.audioStreamLoop(task: task, audioSource: audioSource)
        }

        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task: task, writer: writer)
        }
    }

    func stopTranscribing() {
        guard isTranscribing else { return }
        isTranscribing = false

        if let writer { flushUtterance(writer: writer) }
        self.writer = nil

        sendTask?.cancel()
        sendTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        if let task = webSocketTask {
            let endSignal = URLSessionWebSocketTask.Message.string("")
            Task {
                try? await task.send(endSignal)
                task.cancel(with: .normalClosure, reason: nil)
            }
        }
        webSocketTask = nil
    }

    // MARK: - Audio streaming

    private func audioStreamLoop(task: URLSessionWebSocketTask, audioSource: any AudioSource) async {
        while isTranscribing, !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.pollingInterval)
            } catch {
                break
            }

            let mic = audioSource.drainMicSamples()
            let system = audioSource.drainSystemSamples()
            let mixed = mixToMono(mic: mic, system: system)
            guard !mixed.isEmpty else { continue }

            let pcmData = floatToPCMS16LE(mixed)
            do {
                try await task.send(.data(pcmData))
            } catch {
                logger.error("Failed to send audio data: \(error)")
                break
            }
        }
    }

    // MARK: - Receive loop

    private func receiveLoop(task: URLSessionWebSocketTask, writer: any TranscriptionWriting) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if isTranscribing {
                    logger.error("WebSocket receive error: \(error)")
                }
                break
            }

            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let response = try? JSONDecoder().decode(SonioxResponse.self, from: data)
            else { continue }

            if let code = response.errorCode {
                logger.error("Soniox error \(code): \(response.errorMessage ?? "unknown")")
                break
            }

            await processTokens(response.tokens, writer: writer)

            if response.finished == true {
                logger.info("Soniox session finished")
                break
            }
        }
    }

    // MARK: - Token processing

    private func processTokens(_ tokens: [SonioxToken]?, writer: any TranscriptionWriting) async {
        guard let tokens else { return }

        for token in tokens {
            guard token.isFinal, let text = token.text, !text.isEmpty else { continue }

            if text.hasPrefix("<") {
                flushUtterance(writer: writer)
                continue
            }

            let speaker = token.speaker ?? "0"
            if speaker != pendingUtteranceSpeaker {
                flushUtterance(writer: writer)
                pendingUtteranceSpeaker = speaker
            }
            pendingUtterance += text
        }
    }

    private func flushUtterance(writer: any TranscriptionWriting) {
        let trimmed = pendingUtterance.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let speaker = pendingUtteranceSpeaker {
            writer.append(text: trimmed, speaker: .identified(speaker))
        }
        pendingUtterance = ""
    }

    // MARK: - Config

    private func buildConfig(sampleRate: Int) -> String {
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": "stt-rt-v4",
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1,
            "enable_speaker_diarization": true,
            "enable_endpoint_detection": true,
        ]

        if let lang = selectedLanguage {
            config["language_hints"] = [lang]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    // MARK: - Audio helpers

    private func mixToMono(mic: [Float], system: [Float]) -> [Float] {
        let count = max(mic.count, system.count)
        guard count > 0 else { return [] }
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<mic.count { mixed[i] += mic[i] }
        for i in 0..<system.count { mixed[i] += system[i] }
        let scale: Float = 0.5
        for i in 0..<count { mixed[i] *= scale }
        return mixed
    }

    private func floatToPCMS16LE(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float(Int16.max))
            var le = int16.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        return data
    }
}

// MARK: - Soniox response types

private struct SonioxResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

private struct SonioxToken: Decodable {
    let text: String?
    let isFinal: Bool
    let speaker: String?

    enum CodingKeys: String, CodingKey {
        case text, speaker
        case isFinal = "is_final"
    }
}

// MARK: - Errors

enum SonioxError: Error, CustomStringConvertible {
    case missingAPIKey

    var description: String {
        switch self {
        case .missingAPIKey: "Soniox API key is not configured"
        }
    }
}
