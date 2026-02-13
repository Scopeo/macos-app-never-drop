import AppKit
import Foundation
import os
import ServiceManagement

private let logger = Logger.app(category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusBar = StatusBarController()
    private let callDetector = CallDetector()
    private let transcriptionEngine = TranscriptionEngine()
    private let permissionPanel = PermissionPanel()
    private let transcriptWriter = TranscriptWriter()
    private var audioCapture: AudioCaptureManager?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        setupStatusBar()
        setupCallDetector()
        setupPermissionPanel()

        Task {
            do {
                try await transcriptionEngine.loadModel()
            } catch {
                logger.error("Model load failed: \(error)")
                statusBar.updateState(.error("Transcription model failed to load"))
            }
        }

        callDetector.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRecordingSession()
        callDetector.stopMonitoring()
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusBar.setup()
        statusBar.isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
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
        statusBar.onLanguageChanged = { [weak self] language in
            self?.transcriptionEngine.selectedLanguage = language
        }
        statusBar.onLaunchAtLoginToggled = { [weak self] in
            self?.toggleLaunchAtLogin()
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

    // MARK: - Launch at Login

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            do {
                try service.unregister()
            } catch {
                logger.error("Failed to disable launch at login: \(error)")
            }
        } else {
            do {
                try service.register()
            } catch {
                logger.error("Failed to enable launch at login: \(error)")
            }
        }
        statusBar.isLaunchAtLoginEnabled = service.status == .enabled
    }

    // MARK: - Call lifecycle

    private func onCallDetected() {
        guard transcriptionEngine.isModelLoaded else {
            logger.warning("Call detected but transcription model not loaded")
            return
        }
        statusBar.updateState(.callDetected)
        permissionPanel.show()
    }

    private func startRecordingSession() {
        callDetector.userAcceptedTranscription()
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

        do {
            try transcriptWriter.open()
        } catch {
            logger.error("Transcript file failed to open: \(error)")
            stopRecordingSession()
            statusBar.updateState(.error("Cannot create transcript file"))
            return
        }

        transcriptionEngine.startTranscribing(audioSource: capture, writer: transcriptWriter)
    }

    private func stopRecordingSession() {
        transcriptionEngine.stopTranscribing()
        audioCapture?.stopCapture()
        audioCapture = nil
        transcriptWriter.close()
        permissionPanel.dismiss()
        callDetector.resetToIdle()
        statusBar.updateState(.idle)
    }
}
