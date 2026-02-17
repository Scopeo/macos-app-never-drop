import SwiftUI

struct TranscriptDetailView: View {

    @Bindable var store: TranscriptStore
    let file: TranscriptFile

    @State private var renameSegmentID: UUID?
    @State private var showCopiedFeedback = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(file.segments) { segment in
                    segmentRow(segment)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            copyButton
                .padding(16)
        }
        .navigationTitle(file.displayName)
        .navigationSubtitle(file.customName != nil ? file.dateString : "")
    }

    // MARK: - Copy button

    private var copyButton: some View {
        Button {
            let text = store.fullText(for: file)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { showCopiedFeedback = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showCopiedFeedback = false }
            }
        } label: {
            Label(
                showCopiedFeedback ? "Copied" : "Copy",
                systemImage: showCopiedFeedback ? "checkmark" : "doc.on.doc"
            )
            .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Copy entire transcript to clipboard")
    }

    // MARK: - Segment row

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let ts = segment.timestamp {
                    Text(ts)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                speakerLabel(segment)
            }

            Text(segment.text)
                .font(.system(.body))
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Speaker label (tappable)

    @ViewBuilder
    private func speakerLabel(_ segment: TranscriptSegment) -> some View {
        Button {
            renameSegmentID = segment.id
        } label: {
            Text(segment.speaker)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .popover(isPresented: isRenamePresented(for: segment.id)) {
            SpeakerRenamePopover(
                currentName: segment.speaker,
                onRename: { newName in
                    store.renameSpeaker(fileURL: file.url, segmentID: segment.id, newName: newName)
                    renameSegmentID = nil
                },
                onRenameAll: { newName in
                    store.renameAllOccurrences(fileURL: file.url, oldName: segment.speaker, newName: newName)
                    renameSegmentID = nil
                },
                onCancel: {
                    renameSegmentID = nil
                }
            )
        }
    }

    private func isRenamePresented(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { renameSegmentID == id },
            set: { if !$0 { renameSegmentID = nil } }
        )
    }
}
