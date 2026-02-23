import SwiftUI

enum MainWindowTab: Hashable {
    case transcripts
    case settings
}

@Observable
final class MainWindowState {
    var selectedTab: MainWindowTab = .transcripts
}

struct MainWindowView: View {

    @Bindable var state: MainWindowState
    @Bindable var store: TranscriptStore
    @Bindable var settings: AppSettings

    var body: some View {
        TabView(selection: $state.selectedTab) {
            TranscriptExplorerView(store: store)
                .tabItem {
                    Label("Transcripts", systemImage: "doc.text")
                }
                .tag(MainWindowTab.transcripts)

            SettingsView(settings: settings)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(MainWindowTab.settings)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
