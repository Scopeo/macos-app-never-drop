@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os

private let logger = Logger.app(category: "AudioCapture")

final class AudioCaptureManager: AudioSource, @unchecked Sendable {

    let systemCapture = SystemAudioCapture()
    let micCapture = MicCapture()

    private(set) var isCapturing = false

    static let targetSampleRate: Double = 16_000
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    // MARK: - AudioSource

    var sampleRate: Double { Self.targetSampleRate }

    // MARK: - Public

    func startCapture() throws {
        guard !isCapturing else { return }

        try systemCapture.start()
        do {
            try micCapture.start()
        } catch {
            systemCapture.stop()
            throw error
        }

        isCapturing = true
    }

    func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        micCapture.stop()
        systemCapture.stop()
    }

    func drainSystemSamples() -> [Float] {
        systemCapture.drainSamples()
    }

    func drainMicSamples() -> [Float] {
        micCapture.drainSamples()
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, CustomStringConvertible {
    case failedToCreateTap(OSStatus)
    case failedToCreateAggregateDevice(OSStatus)
    case invalidFormat
    case converterCreationFailed
    case failedToCreateIOProc(OSStatus)
    case failedToStart(OSStatus)
    case cannotReadDevice(OSStatus)

    var description: String {
        switch self {
        case .failedToCreateTap(let s): "Failed to create process tap (OSStatus \(s))"
        case .failedToCreateAggregateDevice(let s): "Failed to create aggregate device (OSStatus \(s))"
        case .invalidFormat: "Could not create AVAudioFormat from stream description"
        case .converterCreationFailed: "Could not create AVAudioConverter for resampling"
        case .failedToCreateIOProc(let s): "Failed to create IO proc (OSStatus \(s))"
        case .failedToStart(let s): "Failed to start audio device (OSStatus \(s))"
        case .cannotReadDevice(let s): "Cannot read audio device property (OSStatus \(s))"
        }
    }
}
