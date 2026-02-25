import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Observation
import os
import SwiftUI

private let logger = Logger.app(category: "App")

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

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

    private struct LastSession {
        let transcriptURL: URL
        let startDate: Date
        let endDate: Date
        let displayLabel: String
    }

    private enum SessionMode {
        case new
        case continuing(url: URL, timeOffset: TimeInterval)
    }

    private var lastSession: LastSession?
    private var currentSessionStartDate: Date?

    private static let continueSessionWindow: TimeInterval = 30 * 60

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
        statusBar.onStartRecording = { [weak self] in
            guard let self else { return }
            guard transcriptionService?.isReady == true else {
                statusBar.updateState(.error("Transcription service not ready"))
                return
            }
            startRecordingSession()
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
        callDetector.probeExternalMicActivity = { [weak self] in
            guard let capture = self?.audioCapture else { return true }
            capture.micCapture.pauseIOProc()
            try? await Task.sleep(for: .milliseconds(100))
            let active = MicrophoneMonitor.allInputDeviceIDs().contains {
                MicrophoneMonitor.isDeviceRunning($0) && !MicrophoneMonitor.isDeviceRunningLocally($0)
            }
            capture.micCapture.resumeIOProc()
            return active
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
        permissionPanel.onContinue = { [weak self] in
            guard let self, let session = lastSession else { return }
            let timeOffset = Date().timeIntervalSince(session.startDate)
            startRecordingSession(mode: .continuing(url: session.transcriptURL, timeOffset: timeOffset))
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
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
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
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
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

        if let session = lastSession,
           Date().timeIntervalSince(session.endDate) < Self.continueSessionWindow {
            permissionPanel.previousSessionLabel = session.displayLabel
        } else {
            permissionPanel.previousSessionLabel = nil
        }

        permissionPanel.show()
    }

    private func startRecordingSession(mode: SessionMode = .new) {
        if audioCapture != nil { return }
        statusBar.updateState(.recording)

        let capture = AudioCaptureManager()
        capture.micCapture.selectedDeviceUID = settings.micDeviceUID
        audioCapture = capture

        do {
            try capture.startCapture()
        } catch {
            logger.error("Audio capture failed to start: \(error)")
            stopRecordingSession()
            statusBar.updateState(.error("Audio capture failed to start"))
            return
        }

        transcriptWriter.userName = settings.userName

        do {
            switch mode {
            case .new:
                try transcriptWriter.open()
                currentSessionStartDate = Date()
            case .continuing(let url, let timeOffset):
                try transcriptWriter.openAppending(to: url, timeOffset: timeOffset)
            }
        } catch {
            logger.error("Transcript file failed to open: \(error)")
            stopRecordingSession()
            statusBar.updateState(.error("Cannot create transcript file"))
            return
        }

        transcriptStore.activeTranscriptURL = transcriptWriter.currentURL
        callDetector.userAcceptedTranscription()

        guard let service = transcriptionService else { return }
        service.selectedLanguage = settings.selectedLanguage
        service.startTranscribing(audioSource: capture, writer: transcriptWriter)
    }

    private func stopRecordingSession() {
        transcriptionService?.stopTranscribing()
        audioCapture?.stopCapture()
        audioCapture = nil

        if let url = transcriptWriter.currentURL, let startDate = currentSessionStartDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            lastSession = LastSession(
                transcriptURL: url,
                startDate: startDate,
                endDate: Date(),
                displayLabel: fmt.string(from: startDate)
            )
        }

        transcriptStore.activeTranscriptURL = nil
        transcriptWriter.close()
        permissionPanel.dismiss()
        callDetector.resetToIdle()
        statusBar.updateState(.idle)
    }
}
