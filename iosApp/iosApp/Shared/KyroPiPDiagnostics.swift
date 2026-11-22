import Foundation
import OSLog

/// Temporary, low-volume diagnostics for physical Build 21 PiP validation.
/// Callers must pass only fixed event labels and playback-state enums/booleans;
/// never media titles, URLs, identifiers, or account data.
enum KyroPiPDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro",
        category: "KYRO_PIP_DIAG"
    )

    static func record(_ event: String, state: String = "") {
        logger.notice("KYRO_PIP_DIAG event=\(event, privacy: .public) state=\(state, privacy: .public)")
        // Build 65: also kept on the device, so a PiP test can be read back without a device log.
        KyroLifecycleJournal.record("pip", event, state)
    }
}
