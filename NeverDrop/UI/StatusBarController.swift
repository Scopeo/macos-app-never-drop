import AppKit

enum StatusBarState: Equatable {
    case idle
    case callDetected
    case recording
    case error(String)
}

@MainActor
final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    var onQuit: (() -> Void)?
    var onOpenTranscripts: (() -> Void)?
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onReportFalsePositive: (() -> Void)?
    var onReportMissedCall: (() -> Void)?

    private(set) var currentState: StatusBarState = .idle

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
        }
        statusItem = item
        rebuildMenu()
    }

    func updateState(_ state: StatusBarState) {
        currentState = state
        if let button = statusItem?.button {
            switch state {
            case .idle, .error:
                button.image = NSImage(named: "MenuBarIcon")
                button.image?.isTemplate = true
            case .callDetected, .recording:
                button.image = NSImage(named: "MenuBarIconActive")
                button.image?.isTemplate = false
            }
            switch state {
            case .idle:
                button.toolTip = "NeverDrop"
            case .callDetected:
                button.toolTip = "NeverDrop — Call Detected"
            case .recording:
                button.toolTip = "NeverDrop — Recording"
            case .error(let msg):
                button.toolTip = "NeverDrop — \(msg)"
            }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let newMenu = NSMenu()

        let statusTitle: String
        switch currentState {
        case .idle: statusTitle = "Status: Idle"
        case .callDetected: statusTitle = "Status: Call Detected"
        case .recording: statusTitle = "Status: Recording..."
        case .error(let msg): statusTitle = "Error: \(msg)"
        }
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        newMenu.addItem(statusMenuItem)

        newMenu.addItem(NSMenuItem.separator())

        switch currentState {
        case .idle, .error:
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecordingAction), keyEquivalent: "s")
            startItem.target = self
            newMenu.addItem(startItem)

            let missedItem = NSMenuItem(title: "Report: missed a call", action: #selector(reportMissedCallAction), keyEquivalent: "")
            missedItem.target = self
            newMenu.addItem(missedItem)

            newMenu.addItem(NSMenuItem.separator())
        case .recording:
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingAction), keyEquivalent: "s")
            stopItem.target = self
            newMenu.addItem(stopItem)

            let falseItem = NSMenuItem(title: "Report: shouldn't be recording", action: #selector(reportFalsePositiveAction), keyEquivalent: "")
            falseItem.target = self
            newMenu.addItem(falseItem)

            newMenu.addItem(NSMenuItem.separator())
        case .callDetected:
            break
        }

        let openItem = NSMenuItem(title: "Transcripts...", action: #selector(openTranscriptsAction), keyEquivalent: "o")
        openItem.target = self
        newMenu.addItem(openItem)

        newMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        newMenu.addItem(settingsItem)

        newMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit NeverDrop", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        newMenu.addItem(quitItem)

        statusItem?.menu = newMenu
        menu = newMenu
    }

    @objc private func startRecordingAction() {
        onStartRecording?()
    }

    @objc private func stopRecordingAction() {
        onStopRecording?()
    }

    @objc private func openTranscriptsAction() {
        onOpenTranscripts?()
    }

    @objc private func openSettingsAction() {
        onOpenSettings?()
    }

    @objc private func quitAction() {
        onQuit?()
    }

    @objc private func reportFalsePositiveAction() {
        onReportFalsePositive?()
    }

    @objc private func reportMissedCallAction() {
        onReportMissedCall?()
    }
}
