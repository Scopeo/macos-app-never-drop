import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Observation
import os
import SwiftUI

private let logger = Logger.app(category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let settings = AppSettings()

    private let statusBar = StatusBarController()
    private let callDetector = CallDetector()
    private let permissionPanel = PermissionPanel()
    private let transcriptWriter = TranscriptWriter()
    private var audioCapture: AudioCaptureManager?

    private var transcriptionService: (any TranscriptionService)?
    private var settingsWindow: NSWindow?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        setupStatusBar()
        setupCallDetector()
        setupPermissionPanel()
        observeProviderChanges()

        Task {
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard micGranted else {
                logger.warning("Microphone permission denied — cannot detect calls")
                statusBar.updateState(.error("Microphone access required"))
                return
            }

            callDetector.startMonitoring()
            await prepareTranscriptionService()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRecordingSession()
        callDetector.stopMonitoring()
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusBar.setup()
        statusBar.onQuit = {
            NSApplication.shared.terminate(nil)
        }
        statusBar.onOpenTranscripts = {
            let url = URL(fileURLWithPath: TranscriptWriter.transcriptsDirectoryPath, isDirectory: true)
            NSWorkspace.shared.open(url)
        }
        statusBar.onStopRecording = { [weak self] in
            self?.stopRecordingSession()
        }
        statusBar.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
    }

    private func setupCallDetector() {
        callDetector.onCallDetected = { [weak self] in
            self?.onCallDetected()
        }
        callDetector.onCallEnded = { [weak self] in
            self?.stopRecordingSession()
        }
    }

    private func setupPermissionPanel() {
        permissionPanel.onAccept = { [weak self] in
            self?.startRecordingSession()
        }
        permissionPanel.onDecline = { [weak self] in
            self?.callDetector.userDeclinedTranscription()
            self?.statusBar.updateState(.idle)
        }
    }

    // MARK: - Settings window

    private func showSettings() {
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "NeverDrop Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 200))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - Transcription service management

    private func makeTranscriptionService() -> any TranscriptionService {
        let service: any TranscriptionService
        switch settings.transcriptionProvider {
        case .whisperLocal:
            service = WhisperTranscriptionService()
        case .sonioxCloud:
            service = SonioxTranscriptionService(apiKey: settings.sonioxAPIKey)
        case .openaiCloud:
            service = OpenAITranscriptionService(apiKey: settings.openaiAPIKey)
        }
        service.selectedLanguage = settings.selectedLanguage
        return service
    }

    private func prepareTranscriptionService() async {
        let service = makeTranscriptionService()
        transcriptionService = service

        do {
            try await service.prepare()
        } catch {
            logger.error("Transcription service failed to prepare: \(error)")
            statusBar.updateState(.error("Transcription service failed to initialize"))
        }
    }

    private func observeProviderChanges() {
        withObservationTracking {
            _ = settings.transcriptionProvider
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleProviderChange()
            }
        }
    }

    private func handleProviderChange() {
        let wasRecording = audioCapture != nil
        if wasRecording {
            transcriptionService?.stopTranscribing()
        }

        Task {
            await prepareTranscriptionService()

            if wasRecording, let capture = audioCapture, let service = transcriptionService, service.isReady {
                service.selectedLanguage = settings.selectedLanguage
                service.startTranscribing(audioSource: capture, writer: transcriptWriter)
            }

            observeProviderChanges()
        }
    }

    // MARK: - Call lifecycle

    private func onCallDetected() {
        guard transcriptionService?.isReady == true else {
            logger.warning("Call detected but transcription service not ready")
            return
        }

        if settings.autoRecordCalls {
            startRecordingSession()
        } else {
            statusBar.updateState(.callDetected)
            permissionPanel.show()
        }
    }

    private func startRecordingSession() {
        statusBar.updateState(.recording)

        let capture = AudioCaptureManager()
        audioCapture = capture

        do {
            try capture.startCapture()
        } catch {
            logger.error("Audio capture failed to start: \(error)")
            stopRecordingSession()
            statusBar.updateState(.error("Audio capture failed to start"))
            return
        }

        let aggregateID = capture.aggregateDeviceID
        if aggregateID != kAudioObjectUnknown {
            callDetector.excludeDevice(aggregateID)
        }

        do {
            try transcriptWriter.open()
        } catch {
            logger.error("Transcript file failed to open: \(error)")
            stopRecordingSession()
            statusBar.updateState(.error("Cannot create transcript file"))
            return
        }

        callDetector.userAcceptedTranscription()

        guard let service = transcriptionService else { return }
        service.selectedLanguage = settings.selectedLanguage
        service.startTranscribing(audioSource: capture, writer: transcriptWriter)
    }

    private func stopRecordingSession() {
        transcriptionService?.stopTranscribing()
        audioCapture?.stopCapture()
        audioCapture = nil
        transcriptWriter.close()
        permissionPanel.dismiss()
        callDetector.clearExclusions()
        callDetector.resetToIdle()
        statusBar.updateState(.idle)
    }
}
