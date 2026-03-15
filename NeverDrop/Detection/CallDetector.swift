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

    var eventLog: DetectionEventLog?

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
        eventLog?.log(.userAction, "user_accepted from=\(state.rawValue)")
        state = .recording
        eventLog?.log(.stateTransition, "idle→recording trigger=user_accepted")
        startPeriodicProbe()
    }

    func userDeclinedTranscription() {
        guard state == .callDetected else { return }
        eventLog?.log(.userAction, "user_declined from=\(state.rawValue)")
        state = .idle
        eventLog?.log(.stateTransition, "callDetected→idle trigger=user_declined")
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .stopping
        eventLog?.log(.stateTransition, "recording→stopping trigger=stopRecording")
        cancelRecordingTasks()
        onCallEnded?()
        state = .idle
        eventLog?.log(.stateTransition, "stopping→idle trigger=callEnded")
    }

    func resetToIdle() {
        cancelAllTasks()
        cooldownUntil = .now + postStopCooldown
        eventLog?.log(.cooldownEvent, "cooldown_started duration=\(postStopCooldown)")
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
                eventLog?.log(.cooldownEvent, "mic_activated_blocked_by_cooldown state=idle")
                return
            }
            cooldownUntil = nil

            eventLog?.log(.debounceEvent, "debounce_started delay=\(activationDelay) state=idle")
            let delay = activationDelay
            debounceTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    self?.eventLog?.log(.debounceEvent, "debounce_cancelled state=\(self?.state.rawValue ?? "?")")
                    return
                }
                guard let self, self.state == .idle else { return }
                self.eventLog?.log(.stateTransition, "idle→callDetected trigger=debounce_elapsed")
                self.state = .callDetected
                self.onCallDetected?()
            }
        case .recording:
            eventLog?.log(.stateTransition, "mic_reactivated_during_recording confirmStop_cancelled")
            confirmStopTask?.cancel()
            confirmStopTask = nil
        case .callDetected, .stopping:
            break
        }
    }

    private func handleMicDeactivated() {
        switch state {
        case .idle:
            eventLog?.log(.debounceEvent, "debounce_cancelled_by_deactivation state=idle")
        case .callDetected:
            eventLog?.log(.stateTransition, "callDetected→idle trigger=mic_deactivated")
            state = .idle
        case .recording:
            eventLog?.log(.probeResult, "mic_deactivated_during_recording triggering_probe")
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
        eventLog?.log(.probeResult, "external_mic_active=\(active) state=\(state.rawValue)")
        guard !Task.isCancelled, state == .recording else { return }

        if active {
            confirmStopTask?.cancel()
            confirmStopTask = nil
            return
        }

        guard confirmStopTask == nil else { return }

        eventLog?.log(.probeResult, "confirmStop_scheduled delay=\(confirmDelay)")
        let delay = confirmDelay
        confirmStopTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.state == .recording else { return }
            guard let probe = self.probeExternalMicActivity else { return }

            let stillInactive = await probe() == false
            self.eventLog?.log(.probeResult, "confirmStop_recheck stillInactive=\(stillInactive)")
            guard !Task.isCancelled, self.state == .recording, stillInactive else {
                self.confirmStopTask = nil
                return
            }
            self.eventLog?.log(.stateTransition, "recording→stopping trigger=probe_confirmed_inactive")
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
