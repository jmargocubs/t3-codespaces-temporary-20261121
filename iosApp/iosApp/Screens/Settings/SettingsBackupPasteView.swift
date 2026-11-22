#if os(iOS)
import SwiftUI

/// Backup & Restore → Paste Backup Text. Imports a backup from its text instead of a file, for when
/// the Files picker can't hand the file to Kyro. The text goes through the same decoder, size
/// limit, integrity check and preview as a file; nothing is applied here. A valid backup closes
/// this screen and shows the usual preview. The text never leaves this screen and is never logged.
struct SettingsBackupPasteView: View {
    let model: SettingsBackupModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Paste the text of a Kyro settings backup, then tap Review. You'll see what would change before anything is applied.")
                        .fixedSize(horizontal: false, vertical: true)
                } footer: {
                    Text("To get the text, tap Copy Settings as Text in Backup & Restore on the device you're copying from. Or open a .kyrosettings file in a text app and copy all of it.")
                }
                .listRowBackground(Color.siloGroupedCell)

                Section {
                    PasteButton(payloadType: String.self) { values in
                        accept(pasted: values.first ?? "")
                    }
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("settingsBackup.pasteButton")

                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Backup text")
                        .accessibilityHint("Paste the whole backup here.")
                        .accessibilityIdentifier("settingsBackup.pasteText")
                } footer: {
                    if !text.isEmpty {
                        Text("\(text.count.formatted()) characters")
                    }
                }
                .listRowBackground(Color.siloGroupedCell)

                if let problem {
                    Section {
                        Label {
                            Text(problem).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                        }
                        .foregroundStyle(Color.siloOnSurface)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Not imported. \(problem)")
                        .accessibilityIdentifier("settingsBackup.pasteProblem")
                    }
                    .listRowBackground(Color.siloGroupedCell)
                }
            }
            .settingsListChrome()
            .navigationTitle("Paste Backup Text")
            .siloNavigationTitleDisplayMode(.inline)
            .siloToolbarColorSchemeDark()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("settingsBackup.pasteCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") { Task { await review() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                        .accessibilityIdentifier("settingsBackup.pasteReview")
                }
            }
            .onChange(of: text) { _, newValue in
                // Text pasted straight into the editor gets the same size limit as the Paste button.
                if newValue.utf8.count > SettingsBackupSafety.maxFileBytes {
                    text = ""
                    problem = SettingsBackupModel.pastedTextMessage(.tooLarge)
                } else if problem != nil, !newValue.isEmpty {
                    problem = nil
                }
            }
        }
    }

    private func accept(pasted: String) {
        guard pasted.utf8.count <= SettingsBackupSafety.maxFileBytes else {
            problem = SettingsBackupModel.pastedTextMessage(.tooLarge)
            return
        }
        text = pasted
        problem = nil
    }

    private func review() async {
        if let message = await model.loadUnifiedImport(text: text) {
            problem = message
        } else {
            dismiss()
        }
    }
}
#endif
