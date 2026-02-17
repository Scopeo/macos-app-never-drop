import CoreAudio
import Foundation

enum CallState: String, Sendable {
    case idle
    case callDetected
    case recording
    case stopping
}

@MainActor
final class CallDetector {

    private(set) var state: CallState = .idle
    var onCallDetected: (@MainActor () -> Void)?
    var onCallEnded: (@MainActor () -> Void)?

    private let micMonitor: any MicrophoneMonitoring
    private var monitorTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var cooldownUntil: ContinuousClock.Instant?

    private let activationDelay: Duration
    private let deactivationDelay: Duration
    private let postStopCooldown: Duration

    init(
        micMonitor: any MicrophoneMonitoring = MicrophoneMonitor(),
        activationDelay: Duration = .seconds(3),
        deactivationDelay: Duration = .seconds(5),
        postStopCooldown: Duration = .seconds(10)
    ) {
        self.micMonitor = micMonitor
        self.activationDelay = activationDelay
        self.deactivationDelay = deactivationDelay
        self.postStopCooldown = postStopCooldown
    }

    // MARK: - Public

    func startMonitoring() {
        let monitor = micMonitor
        monitorTask = Task { [weak self] in
            for await micActive in monitor.statusStream() {
                self?.handleMicChange(isActive: micActive)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    func userAcceptedTranscription() {
        guard state == .callDetected else { return }
        state = .recording
    }

    func userDeclinedTranscription() {
        guard state == .callDetected else { return }
        state = .idle
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .stopping
        onCallEnded?()
        state = .idle
    }

    func resetToIdle() {
        debounceTask?.cancel()
        debounceTask = nil
        cooldownUntil = .now + postStopCooldown
        state = .idle
    }

    func excludeDevice(_ deviceID: AudioDeviceID) {
        micMonitor.excludeDevice(deviceID)
    }

    func clearExclusions() {
        micMonitor.clearExclusions()
    }

    // MARK: - Mic monitoring (call detection)

    private func handleMicChange(isActive: Bool) {
        debounceTask?.cancel()

        if isActive {
            handleMicActivated()
        } else {
            handleMicDeactivated()
        }
    }

    private func handleMicActivated() {
        switch state {
        case .idle:
            if let cooldownUntil, ContinuousClock.now < cooldownUntil {
                return
            }
            cooldownUntil = nil

            let delay = activationDelay
            debounceTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch { return }
                guard let self, self.state == .idle else { return }
                self.state = .callDetected
                self.onCallDetected?()
            }
        case .callDetected, .recording, .stopping:
            break
        }
    }

    private func handleMicDeactivated() {
        switch state {
        case .idle:
            break
        case .callDetected:
            state = .idle
        case .recording:
            let delay = deactivationDelay
            debounceTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch { return }
                guard let self, self.state == .recording else { return }
                self.stopRecording()
            }
        case .stopping:
            break
        }
    }
}
