import CoreAudio

protocol MicrophoneMonitoring: Sendable {
    func statusStream() -> AsyncStream<Bool>
    func excludeDevice(_ deviceID: AudioDeviceID)
    func clearExclusions()
}
