#if os(iOS)
import OSLog
import UIKit
import UniformTypeIdentifiers

/// Opens the Files picker for a settings backup with UIKit, presented straight from the top view
/// controller.
///
/// Builds 88–91 used SwiftUI's `.fileImporter`, attached to the same view as `.fileExporter`. On
/// the iPhone the picker opened and listed the exported `.kyrosettings` file as selectable, but
/// tapping it never returned a file to Kyro: no preview and no error. This presents
/// `UIDocumentPickerViewController` directly instead, so the pick reaches this delegate without
/// going through SwiftUI's shared document-picker presentation.
///
/// `asCopy: true` makes iOS hand Kyro a private copy of the chosen file, so no security-scoped
/// access is needed. The copy is deleted after it has been read.
@MainActor
final class SettingsBackupFilePicker: NSObject, UIDocumentPickerDelegate {
    private static let logger = Logger(subsystem: "com.cubbiestream.kyro", category: "settings.backup")
    private var completion: ((URL?) -> Void)?

    /// Shows the picker. Returns false when there is no view controller to present from.
    @discardableResult
    func present(completion: @escaping (URL?) -> Void) -> Bool {
        guard let presenter = Self.topViewController() else {
            Self.logger.error("import picker: no presenter")
            return false
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: SettingsBackupFileType.importerTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        self.completion = completion
        presenter.present(picker, animated: true)
        Self.logger.info("import picker: presented")
        return true
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Only the extension and a count are logged, never the name or contents.
        Self.logger.info("import picker: picked \(urls.count) item(s), extension \(urls.first?.pathExtension ?? "-", privacy: .public)")
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.logger.info("import picker: cancelled")
        finish(nil)
    }

    private func finish(_ url: URL?) {
        let completion = completion
        self.completion = nil
        completion?(url)
    }

    /// Deletes the private copy the picker made, and only a file inside this app's temporary folder.
    nonisolated static func discardCopy(_ url: URL) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(temporary + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
#endif
