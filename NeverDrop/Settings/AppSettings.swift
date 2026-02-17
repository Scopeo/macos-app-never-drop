import Foundation
import Observation
import ServiceManagement

enum TranscriptionProvider: String, CaseIterable {
    case whisperLocal = "whisper_local"
    case sonioxCloud = "soniox_cloud"
    case openaiCloud = "openai_cloud"

    var displayName: String {
        switch self {
        case .whisperLocal: "Local (WhisperKit)"
        case .sonioxCloud: "Soniox Cloud"
        case .openaiCloud: "OpenAI Cloud"
        }
    }
}

@Observable
final class AppSettings {

    var transcriptionProvider: TranscriptionProvider {
        didSet { defaults.set(transcriptionProvider.rawValue, forKey: Keys.provider) }
    }

    var sonioxAPIKey: String {
        didSet { defaults.set(sonioxAPIKey, forKey: Keys.sonioxAPIKey) }
    }

    var openaiAPIKey: String {
        didSet { defaults.set(openaiAPIKey, forKey: Keys.openaiAPIKey) }
    }

    var selectedLanguage: String? {
        didSet { defaults.set(selectedLanguage, forKey: Keys.language) }
    }

    var isLaunchAtLoginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            let service = SMAppService.mainApp
            if newValue {
                try? service.register()
            } else {
                try? service.unregister()
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let provider = "transcription_provider"
        static let sonioxAPIKey = "soniox_api_key"
        static let openaiAPIKey = "openai_api_key"
        static let language = "selected_language"
    }

    init() {
        let defaults = UserDefaults.standard
        self.transcriptionProvider = TranscriptionProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .whisperLocal
        self.sonioxAPIKey = defaults.string(forKey: Keys.sonioxAPIKey) ?? ""
        self.openaiAPIKey = defaults.string(forKey: Keys.openaiAPIKey) ?? ""
        self.selectedLanguage = defaults.string(forKey: Keys.language)
    }
}
