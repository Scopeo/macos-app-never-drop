import CoreAudio

protocol MicrophoneMonitoring: Sendable {
    func statusStream() -> AsyncStream<Bool>
}
