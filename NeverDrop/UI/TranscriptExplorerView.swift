import SwiftUI

struct TranscriptExplorerView: View {

    @Bindable var store: TranscriptStore
    @State private var renamingFileURL: URL?
    @State private var renameText = ""
    @State private var showDeleteConfirmation = false

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
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(store.files, selection: $store.selectedFileURLs) { file in
            sidebarRow(file)
                .tag(file.url)
                .contextMenu {
                    Button("Rename...") {
                        renameText = file.customName ?? ""
                        renamingFileURL = file.url
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        store.selectedFileURLs = [file.url]
                        showDeleteConfirmation = true
                    }
                }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    store.loadFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete selected")
                .disabled(store.selectedFileURLs.isEmpty)
            }
        }
        .sheet(isPresented: isRenamingPresented) {
            renameSheet
        }
    }

    // MARK: - Sidebar row

    @ViewBuilder
    private func sidebarRow(_ file: TranscriptFile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.displayName)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)
            Text(file.customName != nil ? file.dateString : relativeDateString(file.date))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Rename sheet

    private var isRenamingPresented: Binding<Bool> {
        Binding(
            get: { renamingFileURL != nil },
            set: { if !$0 { renamingFileURL = nil } }
        )
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Conversation")
                .font(.headline)

            TextField("Conversation name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename() }

            Text("Leave empty to use the date as name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { renamingFileURL = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func commitRename() {
        guard let url = renamingFileURL else { return }
        store.renameConversation(fileURL: url, newName: renameText)
        renamingFileURL = nil
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
                description: Text("Select a single transcript to view it, or use the toolbar to delete.")
            )
        } else {
            ContentUnavailableView(
                "Select a Transcript",
                systemImage: "doc.text",
                description: Text("Choose a transcript from the sidebar to view it.")
            )
        }
    }

    // MARK: - Helpers

    private func relativeDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
