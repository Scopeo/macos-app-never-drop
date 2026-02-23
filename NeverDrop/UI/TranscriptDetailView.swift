import SwiftUI

struct TranscriptDetailView: View {

    @Bindable var store: TranscriptStore
    let file: TranscriptFile

    @State private var renameSegmentID: UUID?
    @State private var showCopiedFeedback = false
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var metaSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                refreshButton
                copyButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(file.segments) { segment in
                        segmentRow(segment)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(file.displayName)
        .navigationSubtitle(file.customName != nil ? file.dateString : "")
    }

    // MARK: - Refresh button

    private var refreshButton: some View {
        Button {
            store.loadFiles()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Refresh transcripts")
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
                        .font(.system(size: metaSize, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                speakerLabel(segment)
            }

            Text(segment.text)
                .font(.system(size: bodySize))
                .lineSpacing(5)
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
                .font(.system(size: metaSize, weight: .semibold))
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
