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

    private let transcriptStore = TranscriptStore()
    private let mainWindowState = MainWindowState()

    private var transcriptionService: (any TranscriptionService)?
    private var mainWindow: NSWindow?
    private var micProbeTask: Task<Void, Never>?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        setupMainMenu()
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
        statusBar.onOpenTranscripts = { [weak self] in
            self?.showMainWindow(tab: .transcripts)
        }
        statusBar.onStopRecording = { [weak self] in
            self?.stopRecordingSession()
        }
        statusBar.onOpenSettings = { [weak self] in
            self?.showMainWindow(tab: .settings)
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

    // MARK: - Main menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Never Drop")
        appMenu.addItem(withTitle: "About Never Drop", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Never Drop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    // MARK: - Main window

    private func showMainWindow(tab: MainWindowTab) {
        mainWindowState.selectedTab = tab

        if let existing = mainWindow {
            if tab == .transcripts { transcriptStore.loadFiles() }
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.setActivationPolicy(.regular)
            NSApp.activate()
            return
        }

        if tab == .transcripts { transcriptStore.loadFiles() }

        let rootView = MainWindowView(
            state: mainWindowState,
            store: transcriptStore,
            settings: settings
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Never Drop"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1150, height: 750))
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        mainWindow = window

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func mainWindowDidClose(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
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

        statusBar.updateState(.callDetected)
        permissionPanel.show()
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

        transcriptWriter.userName = settings.userName

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

        startMicProbe()
    }

    // MARK: - External mic probe

    private func startMicProbe() {
        micProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.performMicProbe()
            }
        }
    }

    private func performMicProbe() async {
        guard let capture = audioCapture, callDetector.state == .recording else { return }

        let micDeviceID = capture.inputDeviceID
        guard micDeviceID != kAudioObjectUnknown else { return }

        capture.stopCapture()
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }

        let micStillExternallyActive = MicrophoneMonitor.allInputDeviceIDs().contains {
            MicrophoneMonitor.isDeviceRunning($0) && !MicrophoneMonitor.isDeviceRunningLocally($0)
        }

        if micStillExternallyActive {
            do {
                try capture.startCapture()
                let aggregateID = capture.aggregateDeviceID
                if aggregateID != kAudioObjectUnknown {
                    callDetector.excludeDevice(aggregateID)
                }
            } catch {
                logger.error("Failed to restart audio capture after probe: \(error)")
                stopRecordingSession()
            }
        } else {
            logger.info("Mic no longer in external use — ending recording session")
            stopRecordingSession()
        }
    }

    private func stopRecordingSession() {
        micProbeTask?.cancel()
        micProbeTask = nil
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
