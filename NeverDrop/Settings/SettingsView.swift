import SwiftUI

struct SettingsView: View {

    @Bindable var settings: AppSettings

    private static let languages: [(code: String?, label: String)] = [
        (nil, "Auto-detect"),
        ("en", "English"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
    ]

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Your Name", text: $settings.userName)
            }

            Section("Transcription") {
                Picker("Provider", selection: $settings.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                if settings.transcriptionProvider == .sonioxCloud {
                    SecureField("Soniox API Key", text: $settings.sonioxAPIKey)
                }

                if settings.transcriptionProvider == .openaiCloud {
                    SecureField("OpenAI API Key", text: $settings.openaiAPIKey)
                }

                Picker("Language", selection: languageBinding) {
                    ForEach(Self.languages, id: \.label) { option in
                        Text(option.label).tag(option.code as String?)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $settings.isLaunchAtLoginEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { settings.selectedLanguage },
            set: { settings.selectedLanguage = $0 }
        )
    }
}
