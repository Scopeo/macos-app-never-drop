import Foundation
import Observation
import os
import ServiceManagement

private let logger = Logger.app(category: "Settings")

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

    var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }

    var isLaunchAtLoginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            let service = SMAppService.mainApp
            if newValue {
                do {
                    try service.register()
                } catch {
                    logger.error("Failed to enable launch at login: \(error)")
                }
            } else {
                do {
                    try service.unregister()
                } catch {
                    logger.error("Failed to disable launch at login: \(error)")
                }
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let provider = "transcription_provider"
        static let sonioxAPIKey = "soniox_api_key"
        static let openaiAPIKey = "openai_api_key"
        static let language = "selected_language"
        static let userName = "user_name"
    }

    init() {
        let defaults = UserDefaults.standard
        self.transcriptionProvider = TranscriptionProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .whisperLocal
        self.sonioxAPIKey = defaults.string(forKey: Keys.sonioxAPIKey) ?? ""
        self.openaiAPIKey = defaults.string(forKey: Keys.openaiAPIKey) ?? ""
        self.selectedLanguage = defaults.string(forKey: Keys.language)
        self.userName = defaults.string(forKey: Keys.userName) ?? ""
    }
}
