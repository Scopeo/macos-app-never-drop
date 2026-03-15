import CoreAudio
import SwiftUI

struct SettingsView: View {

    @Bindable var settings: AppSettings
    @State private var inputDevices: [(uid: String, name: String)] = []

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

            Section("Audio") {
                Picker("Microphone", selection: micDeviceBinding) {
                    Text("System Default").tag(nil as String?)
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Transcription") {
                Picker("Provider", selection: $settings.transcriptionProvider) {
                    ForEach(TranscriptionProvider.availableProviders, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

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
                .pickerStyle(.menu)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: $settings.isLaunchAtLoginEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshInputDevices() }
    }

    private var languageBinding: Binding<String?> {
        Binding(
            get: { settings.selectedLanguage },
            set: { settings.selectedLanguage = $0 }
        )
    }

    private var micDeviceBinding: Binding<String?> {
        Binding(
            get: { settings.micDeviceUID },
            set: { settings.micDeviceUID = $0 }
        )
    }

    private func refreshInputDevices() {
        inputDevices = MicrophoneMonitor.allInputDeviceIDs().compactMap { id in
            guard let name = MicrophoneMonitor.deviceName(id),
                  let uid = MicCapture.deviceUID(id) else { return nil }
            return (uid: uid, name: name)
        }
    }
}
