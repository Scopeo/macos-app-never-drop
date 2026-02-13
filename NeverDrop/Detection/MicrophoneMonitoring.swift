protocol MicrophoneMonitoring: Sendable {
    func statusStream() -> AsyncStream<Bool>
}
