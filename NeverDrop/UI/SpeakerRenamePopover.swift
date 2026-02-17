import SwiftUI

struct SpeakerRenamePopover: View {

    let currentName: String
    let onRename: (String) -> Void
    let onRenameAll: (String) -> Void
    let onCancel: () -> Void

    @State private var newName: String

    init(
        currentName: String,
        onRename: @escaping (String) -> Void,
        onRenameAll: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentName = currentName
        self.onRename = onRename
        self.onRenameAll = onRenameAll
        self.onCancel = onCancel
        self._newName = State(initialValue: currentName)
    }

    private var hasChanges: Bool {
        !newName.isEmpty && newName != currentName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speaker")
                .font(.headline)

            TextField("Speaker name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit {
                    if hasChanges { onRename(newName) }
                }

            HStack(spacing: 8) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Rename") {
                    onRename(newName)
                }
                .disabled(!hasChanges)

                Button("Rename All \"\(currentName)\"") {
                    onRenameAll(newName)
                }
                .disabled(!hasChanges)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
