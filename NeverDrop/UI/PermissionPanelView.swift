import SwiftUI

struct PermissionPanelView: View {

    var onAccept: () -> Void
    var onDecline: () -> Void
    var onContinue: (() -> Void)? = nil
    var onReportFalsePositive: (() -> Void)? = nil
    var previousSessionLabel: String? = nil

    @State private var secondsRemaining = 15

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text("Call Detected")
                .font(.headline)

            Text("Before starting transcription, make sure all participants have been informed and have given their consent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Ignore") {
                    onDecline()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Transcribe") {
                    onAccept()
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }

            if let onContinue, let label = previousSessionLabel {
                Button("Resume \(label) transcript") {
                    onContinue()
                }
                .font(.subheadline)
            }

            HStack(spacing: 16) {
                Text("Auto-dismiss in \(secondsRemaining)s")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if let onReportFalsePositive {
                    Button("Not a call? Report") {
                        onReportFalsePositive()
                        onDecline()
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
        .frame(width: 320)
        .task {
            await autoDismissCountdown()
        }
    }

    private func autoDismissCountdown() async {
        while secondsRemaining > 0 {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch { return }
            secondsRemaining -= 1
        }
        onDecline()
    }
}
