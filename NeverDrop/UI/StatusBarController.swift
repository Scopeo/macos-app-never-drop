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
    var onStopRecording: (() -> Void)?
    var onOpenSettings: (() -> Void)?

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

        if currentState == .recording {
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecordingAction), keyEquivalent: "s")
            stopItem.target = self
            newMenu.addItem(stopItem)
            newMenu.addItem(NSMenuItem.separator())
        }

        let openItem = NSMenuItem(title: "Open Transcripts Folder", action: #selector(openTranscriptsAction), keyEquivalent: "o")
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
}
