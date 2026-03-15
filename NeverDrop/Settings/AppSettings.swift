import Foundation
import Observation
import os
import Sentry
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

    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    static var availableProviders: [TranscriptionProvider] {
        isAppleSilicon ? allCases : allCases.filter { $0 != .whisperLocal }
    }

    static var defaultProvider: TranscriptionProvider {
        isAppleSilicon ? .whisperLocal : .sonioxCloud
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

    /// nil = follow system default input; otherwise a specific device UID
    var micDeviceUID: String? {
        didSet { defaults.set(micDeviceUID, forKey: Keys.micDeviceUID) }
    }

    var analyticsConsent: Bool {
        didSet {
            defaults.set(analyticsConsent, forKey: Keys.analyticsConsent)
            if analyticsConsent {
                SentryManager.start(settings: self)
            } else {
                SentryManager.stop()
            }
        }
    }

    var hasBeenAskedForConsent: Bool {
        didSet { defaults.set(hasBeenAskedForConsent, forKey: Keys.hasBeenAskedForConsent) }
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
                    SentrySDK.capture(error: error)
                }
            } else {
                do {
                    try service.unregister()
                } catch {
                    logger.error("Failed to disable launch at login: \(error)")
                    SentrySDK.capture(error: error)
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
        static let micDeviceUID = "mic_device_uid"
        static let analyticsConsent = "analytics_consent"
        static let hasBeenAskedForConsent = "has_been_asked_for_consent"
    }

    init() {
        let defaults = UserDefaults.standard
        let persisted = TranscriptionProvider(rawValue: defaults.string(forKey: Keys.provider) ?? "")
        self.transcriptionProvider = persisted.flatMap { TranscriptionProvider.availableProviders.contains($0) ? $0 : nil }
            ?? TranscriptionProvider.defaultProvider
        self.sonioxAPIKey = defaults.string(forKey: Keys.sonioxAPIKey) ?? ""
        self.openaiAPIKey = defaults.string(forKey: Keys.openaiAPIKey) ?? ""
        self.selectedLanguage = defaults.string(forKey: Keys.language)
        self.userName = defaults.string(forKey: Keys.userName) ?? ""
        self.micDeviceUID = defaults.string(forKey: Keys.micDeviceUID)
        self.analyticsConsent = defaults.bool(forKey: Keys.analyticsConsent)
        self.hasBeenAskedForConsent = defaults.bool(forKey: Keys.hasBeenAskedForConsent)
    }
}
