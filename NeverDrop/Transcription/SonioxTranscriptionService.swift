import Foundation
import Observation
import os
import Sentry

private let logger = Logger.app(category: "Soniox")

@MainActor
@Observable
final class SonioxTranscriptionService: TranscriptionService {

    private(set) var isReady = false

    var selectedLanguage: String?

    private let apiKey: String

    private var micWebSocket: URLSessionWebSocketTask?
    private var systemWebSocket: URLSessionWebSocketTask?
    private var micSendTask: Task<Void, Never>?
    private var systemSendTask: Task<Void, Never>?
    private var micReceiveTask: Task<Void, Never>?
    private var systemReceiveTask: Task<Void, Never>?

    private var isTranscribing = false
    private var writer: (any TranscriptionWriting)?

    private var micPendingUtterance = ""
    private var systemPendingUtterance = ""
    private var systemPendingUtteranceSpeaker: String?
    private var speakerMapping: [String: String] = [:]
    private var nextSpeakerNumber = 1
    private var recordingStartDate: Date?

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
        micPendingUtterance = ""
        systemPendingUtterance = ""
        systemPendingUtteranceSpeaker = nil
        speakerMapping = [:]
        nextSpeakerNumber = 1
        recordingStartDate = Date()

        let sampleRate = Int(audioSource.sampleRate)

        let micTask = URLSession.shared.webSocketTask(with: Self.sonioxURL)
        micWebSocket = micTask
        micTask.resume()

        let systemTask = URLSession.shared.webSocketTask(with: Self.sonioxURL)
        systemWebSocket = systemTask
        systemTask.resume()

        let micConfig = buildConfig(sampleRate: sampleRate, enableDiarization: false)
        let systemConfig = buildConfig(sampleRate: sampleRate, enableDiarization: true)

        micSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await micTask.send(.string(micConfig))
            } catch {
                logger.error("Failed to send Soniox mic config: \(error)")
                SentrySDK.capture(error: error)
                return
            }
            await self.audioStreamLoop(task: micTask, audioSource: audioSource, channel: .mic)
        }

        systemSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await systemTask.send(.string(systemConfig))
            } catch {
                logger.error("Failed to send Soniox system config: \(error)")
                SentrySDK.capture(error: error)
                return
            }
            await self.audioStreamLoop(task: systemTask, audioSource: audioSource, channel: .system)
        }

        micReceiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task: micTask, writer: writer, channel: .mic)
        }

        systemReceiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task: systemTask, writer: writer, channel: .system)
        }
    }

    func stopTranscribing() {
        guard isTranscribing else { return }
        isTranscribing = false

        if let writer {
            flushMicUtterance(writer: writer)
            flushSystemUtterance(writer: writer)
        }
        self.writer = nil

        micSendTask?.cancel()
        micSendTask = nil
        systemSendTask?.cancel()
        systemSendTask = nil
        micReceiveTask?.cancel()
        micReceiveTask = nil
        systemReceiveTask?.cancel()
        systemReceiveTask = nil

        closeWebSocket(micWebSocket)
        micWebSocket = nil
        closeWebSocket(systemWebSocket)
        systemWebSocket = nil
    }

    // MARK: - Audio streaming

    private enum AudioChannel {
        case mic, system
    }

    private func audioStreamLoop(task: URLSessionWebSocketTask, audioSource: any AudioSource, channel: AudioChannel) async {
        while isTranscribing, !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.pollingInterval)
            } catch { break }

            let samples: [Float]
            switch channel {
            case .mic: samples = audioSource.drainMicSamples()
            case .system: samples = audioSource.drainSystemSamples()
            }
            guard !samples.isEmpty else { continue }

            let pcmData = floatToPCMS16LE(samples)
            do {
                try await task.send(.data(pcmData))
            } catch {
                logger.error("Failed to send \(String(describing: channel)) audio data: \(error)")
                SentrySDK.capture(error: error)
                break
            }
        }
    }

    // MARK: - Receive loop

    private func receiveLoop(task: URLSessionWebSocketTask, writer: any TranscriptionWriting, channel: AudioChannel) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if isTranscribing {
                    logger.error("Soniox \(String(describing: channel)) WebSocket receive error: \(error)")
                    SentrySDK.capture(error: error)
                }
                break
            }

            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let response = try? JSONDecoder().decode(SonioxResponse.self, from: data)
            else { continue }

            if let code = response.errorCode {
                logger.error("Soniox \(String(describing: channel)) error \(code): \(response.errorMessage ?? "unknown")")
                SentrySDK.capture(message: "Soniox \(channel) error \(code): \(response.errorMessage ?? "unknown")")
                break
            }

            await processTokens(response.tokens, writer: writer, channel: channel)

            if response.finished == true {
                logger.info("Soniox \(String(describing: channel)) session finished")
                break
            }
        }
    }

    // MARK: - Token processing

    private func processTokens(_ tokens: [SonioxToken]?, writer: any TranscriptionWriting, channel: AudioChannel) async {
        guard let tokens else { return }

        for token in tokens {
            guard token.isFinal, let text = token.text, !text.isEmpty else { continue }

            if text.hasPrefix("<") {
                switch channel {
                case .mic: flushMicUtterance(writer: writer)
                case .system: flushSystemUtterance(writer: writer)
                }
                continue
            }

            switch channel {
            case .mic:
                micPendingUtterance += text

            case .system:
                let speaker = token.speaker ?? "0"
                if speaker != systemPendingUtteranceSpeaker {
                    flushSystemUtterance(writer: writer)
                    systemPendingUtteranceSpeaker = speaker
                }
                systemPendingUtterance += text
            }
        }
    }

    private func flushMicUtterance(writer: any TranscriptionWriting) {
        let trimmed = micPendingUtterance.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let relativeTime = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
            writer.append(text: trimmed, speaker: .you, relativeTime: relativeTime)
        }
        micPendingUtterance = ""
    }

    private func flushSystemUtterance(writer: any TranscriptionWriting) {
        let trimmed = systemPendingUtterance.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let apiID = systemPendingUtteranceSpeaker {
            let mappedID = mapSpeaker(apiID)
            let relativeTime = recordingStartDate.map { Date().timeIntervalSince($0) } ?? 0
            writer.append(text: trimmed, speaker: .identified(mappedID), relativeTime: relativeTime)
        }
        systemPendingUtterance = ""
    }

    // MARK: - Speaker mapping

    private func mapSpeaker(_ apiID: String) -> String {
        if let mapped = speakerMapping[apiID] { return mapped }
        let number = String(nextSpeakerNumber)
        speakerMapping[apiID] = number
        nextSpeakerNumber += 1
        return number
    }

    // MARK: - Config

    private func buildConfig(sampleRate: Int, enableDiarization: Bool) -> String {
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": "stt-rt-v4",
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1,
            "enable_speaker_diarization": enableDiarization,
            "enable_endpoint_detection": true,
        ]

        if let lang = selectedLanguage {
            config["language_hints"] = [lang]
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: config)
            guard let json = String(data: data, encoding: .utf8) else {
                logger.error("Failed to encode Soniox config as UTF-8")
                return "{}"
            }
            return json
        } catch {
            logger.error("Failed to serialize Soniox config: \(error)")
            SentrySDK.capture(error: error)
            return "{}"
        }
    }

    // MARK: - Helpers

    private func closeWebSocket(_ task: URLSessionWebSocketTask?) {
        guard let task else { return }
        Task {
            try? await task.send(.string(""))
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func floatToPCMS16LE(_ samples: [Float]) -> Data {
        AudioEncoding.floatToPCMS16LE(samples)
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
