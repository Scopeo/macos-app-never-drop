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
        Group {
            switch state.selectedTab {
            case .transcripts:
                TranscriptExplorerView(store: store)
            case .settings:
                SettingsView(settings: settings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Tab", selection: $state.selectedTab) {
                    Label("Transcripts", systemImage: "doc.text")
                        .tag(MainWindowTab.transcripts)
                    Label("Settings", systemImage: "gear")
                        .tag(MainWindowTab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
