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

    /// Injected by the coordinator. Pauses mic IOProc, checks if any input device
    /// is still in use by another process, resumes IOProc. Returns true when an
    /// external app is still holding a microphone.
    var probeExternalMicActivity: (@MainActor () async -> Bool)?

    private let micMonitor: any MicrophoneMonitoring
    private var monitorTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var confirmStopTask: Task<Void, Never>?
    private var cooldownUntil: ContinuousClock.Instant?

    private let activationDelay: Duration
    private let probeInterval: Duration
    private let confirmDelay: Duration
    private let postStopCooldown: Duration

    init(
        micMonitor: any MicrophoneMonitoring = MicrophoneMonitor(),
        activationDelay: Duration = .seconds(3),
        probeInterval: Duration = .seconds(10),
        confirmDelay: Duration = .seconds(5),
        postStopCooldown: Duration = .seconds(10)
    ) {
        self.micMonitor = micMonitor
        self.activationDelay = activationDelay
        self.probeInterval = probeInterval
        self.confirmDelay = confirmDelay
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
        cancelAllTasks()
    }

    func userAcceptedTranscription() {
        guard state == .callDetected || state == .idle else { return }
        debounceTask?.cancel()
        debounceTask = nil
        cooldownUntil = nil
        state = .recording
        startPeriodicProbe()
    }

    func userDeclinedTranscription() {
        guard state == .callDetected else { return }
        state = .idle
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .stopping
        cancelRecordingTasks()
        onCallEnded?()
        state = .idle
    }

    func resetToIdle() {
        cancelAllTasks()
        cooldownUntil = .now + postStopCooldown
        state = .idle
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
        case .recording:
            confirmStopTask?.cancel()
            confirmStopTask = nil
        case .callDetected, .stopping:
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
            triggerProbe()
        case .stopping:
            break
        }
    }

    // MARK: - Probe logic

    private func startPeriodicProbe() {
        probeTask?.cancel()
        let interval = probeInterval
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.runProbe()
            }
        }
    }

    private func triggerProbe() {
        Task { await runProbe() }
    }

    private func runProbe() async {
        guard state == .recording, let probe = probeExternalMicActivity else { return }

        let active = await probe()
        guard !Task.isCancelled, state == .recording else { return }

        if active {
            confirmStopTask?.cancel()
            confirmStopTask = nil
            return
        }

        guard confirmStopTask == nil else { return }

        let delay = confirmDelay
        confirmStopTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.state == .recording else { return }
            guard let probe = self.probeExternalMicActivity else { return }

            let stillInactive = await probe() == false
            guard !Task.isCancelled, self.state == .recording, stillInactive else {
                self.confirmStopTask = nil
                return
            }
            self.stopRecording()
        }
    }

    // MARK: - Task management

    private func cancelRecordingTasks() {
        probeTask?.cancel()
        probeTask = nil
        confirmStopTask?.cancel()
        confirmStopTask = nil
    }

    private func cancelAllTasks() {
        debounceTask?.cancel()
        debounceTask = nil
        cancelRecordingTasks()
    }
}
