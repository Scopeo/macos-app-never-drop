import SwiftUI

@main
struct NeverDropApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu-bar-only app: no main window.
        // The StatusBarController in AppDelegate drives the UI.
        Settings {
            EmptyView()
        }
    }
}
