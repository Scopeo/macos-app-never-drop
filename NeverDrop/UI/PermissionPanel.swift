import AppKit
import SwiftUI

final class PermissionPanel {

    private var panel: NSPanel?

    var onAccept: (() -> Void)?
    var onDecline: (() -> Void)?

    func show() {
        guard panel == nil else { return }

        let view = PermissionPanelView(
            onAccept: { [weak self] in self?.accept() },
            onDecline: { [weak self] in self?.decline() }
        )

        let hostingController = NSHostingController(rootView: view)

        let newPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.titlebarAppearsTransparent = true
        newPanel.titleVisibility = .hidden
        newPanel.isMovableByWindowBackground = true
        newPanel.contentViewController = hostingController

        newPanel.center()
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelSize = hostingController.view.fittingSize
            let origin = NSPoint(
                x: screenFrame.midX - panelSize.width / 2,
                y: screenFrame.maxY - panelSize.height - 40
            )
            newPanel.setFrameOrigin(origin)
        }

        newPanel.makeKeyAndOrderFront(nil)
        panel = newPanel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }

    private func accept() {
        dismiss()
        onAccept?()
    }

    private func decline() {
        dismiss()
        onDecline?()
    }
}
