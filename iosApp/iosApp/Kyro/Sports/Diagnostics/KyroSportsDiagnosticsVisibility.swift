import Foundation

/// Whether Sports Hub's internal diagnostics (the Sports Match Report) appear in the stream picker
/// and Other Streams.
///
/// They are compiled only into internal test builds, and even there they stay out of the normal
/// interface until a developer turns them on under Live TV Settings > Internal Test. The report
/// builder, its store and its export are unchanged; only where its controls appear is gated.
enum KyroSportsDiagnosticsVisibility {
    static let defaultsKey = "kyro.internal.sportsDiagnosticsVisible"

    static var isCompiledIn: Bool {
        #if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
        true
        #else
        false
        #endif
    }

    static func showsMatchReport(isCompiledIn: Bool, isEnabled: Bool) -> Bool {
        isCompiledIn && isEnabled
    }
}
