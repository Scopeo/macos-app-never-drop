import SwiftUI
import AppKit

private struct DoubleClickDetector: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ClickView { ClickView(onDoubleClick: onDoubleClick) }
    func updateNSView(_ view: ClickView, context: Context) { view.onDoubleClick = onDoubleClick }

    final class ClickView: NSView {
        var onDoubleClick: () -> Void
        init(onDoubleClick: @escaping () -> Void) {
            self.onDoubleClick = onDoubleClick
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
            } else {
                nextResponder?.mouseDown(with: event)
            }
        }
        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
        }
    }
}

struct TranscriptExplorerView: View {

    @Bindable var store: TranscriptStore
    @State private var editingFileURL: URL?
    @State private var editText = ""
    @State private var showDeleteConfirmation = false
    @State private var showMergeConfirmation = false
    @FocusState private var isEditingFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            store.loadFiles()
        }
        .alert("Delete Transcripts", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteFiles(urls: store.selectedFileURLs)
            }
        } message: {
            let count = store.selectedFileURLs.count
            Text("Are you sure you want to delete \(count) transcript\(count == 1 ? "" : "s")? This cannot be undone.")
        }
        .alert("Merge Transcripts", isPresented: $showMergeConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Merge") {
                store.mergeFiles(urls: store.selectedFileURLs)
            }
        } message: {
            let count = store.selectedFileURLs.count
            Text("Merge \(count) transcripts into one? Timestamps will be re-aligned. The originals will be moved to Trash.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $store.selectedFileURLs) {
            ForEach(sidebarItems) { item in
                switch item {
                case .yearHeader(let year):
                    yearHeaderView(year)
                case .file(let file):
                    sidebarRow(file)
                        .tag(file.url)
                        .contextMenu {
                            Button("Rename...") { beginEditing(file) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.selectedFileURLs = [file.url]
                                showDeleteConfirmation = true
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.selectedFileURLs.isEmpty)
                .help("Delete selected")

                Spacer()

                if store.selectedFileURLs.count >= 2 {
                    let activeSelected = store.activeTranscriptURL.map { store.selectedFileURLs.contains($0) } ?? false
                    Button("Merge") {
                        showMergeConfirmation = true
                    }
                    .buttonStyle(.borderless)
                    .disabled(activeSelected)
                    .help(activeSelected ? "Cannot merge while a transcription is in progress" : "Merge selected transcripts into one")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Sidebar items (flat list with optional year headers)

    private enum SidebarItem: Identifiable {
        case yearHeader(Int)
        case file(TranscriptFile)

        var id: String {
            switch self {
            case .yearHeader(let year): return "year-\(year)"
            case .file(let f): return f.url.absoluteString
            }
        }
    }

    private var sidebarItems: [SidebarItem] {
        let calendar = Calendar.current
        let years = Set(store.files.map { calendar.component(.year, from: $0.date) })
        let showYearHeaders = years.count > 1

        var items: [SidebarItem] = []
        var currentYear: Int?

        for file in store.files {
            let year = calendar.component(.year, from: file.date)
            if showYearHeaders && year != currentYear {
                items.append(.yearHeader(year))
                currentYear = year
            }
            items.append(.file(file))
        }
        return items
    }

    // MARK: - Year header

    private func yearHeaderView(_ year: Int) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(String(year))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }

    // MARK: - Sidebar row

    @ViewBuilder
    private func sidebarRow(_ file: TranscriptFile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if editingFileURL == file.url {
                TextField("Conversation name", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, weight: .medium))
                    .focused($isEditingFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelEditing() }
            } else {
                Text(file.customName ?? smartDateString(file.date))
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                    .overlay(DoubleClickDetector { beginEditing(file) })
            }

            if file.customName != nil {
                Text(smartDateString(file.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Inline rename

    private func beginEditing(_ file: TranscriptFile) {
        editText = file.customName ?? smartDateString(file.date)
        editingFileURL = file.url
        DispatchQueue.main.async {
            isEditingFocused = true
        }
    }

    private func commitRename() {
        guard let url = editingFileURL else { return }
        store.renameConversation(fileURL: url, newName: editText)
        editingFileURL = nil
    }

    private func cancelEditing() {
        editingFileURL = nil
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let file = store.selectedFile {
            TranscriptDetailView(store: store, file: file)
        } else if store.selectedFileURLs.count > 1 {
            ContentUnavailableView(
                "\(store.selectedFileURLs.count) Transcripts Selected",
                systemImage: "doc.on.doc",
                description: Text("Select a single transcript to view it, or merge / delete the selection.")
            )
        } else {
            ContentUnavailableView(
                "Select a Transcript",
                systemImage: "doc.text",
                description: Text("Choose a transcript from the sidebar to view it.")
            )
        }
    }

    // MARK: - Smart date formatting

    private func smartDateString(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            return "Today, \(tf.string(from: date))"
        }

        if calendar.isDateInYesterday(date) {
            let tf = DateFormatter()
            tf.dateFormat = "HH:mm"
            return "Yesterday, \(tf.string(from: date))"
        }

        let df = DateFormatter()
        df.dateFormat = "EEEE d MMM"
        return df.string(from: date)
    }
}
