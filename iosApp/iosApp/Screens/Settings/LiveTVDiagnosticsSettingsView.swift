#if os(iOS)
import SwiftUI

/// Settings → Advanced & Diagnostics → Live TV Diagnostics. The controls moved
/// here unchanged from the Live TV provider page: same stores, same actions,
/// same restart notes. The internal test sections still compile only into
/// the owner's experimental build.
struct LiveTVDiagnosticsSettingsView: View {
    @Bindable var service: LiveTVService
    @AppStorage(KyroPerformanceDiagnostics.defaultsKey) private var performanceOverlayEnabled = false
    @State private var journalCopyStatus: String?
    #if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
    @AppStorage(EPGStorageMode.defaultsKey) private var sqliteStorageEnabled = false
    @AppStorage(KyroSportsDiagnosticsVisibility.defaultsKey) private var sportsDiagnosticsVisible = false
    #endif

    var body: some View {
        List {
            Section {
                Toggle("Performance overlay", isOn: $performanceOverlayEnabled)
                    .foregroundStyle(Color.siloOnSurface)
                    .tint(.siloSwitchOn)
                    .accessibilityIdentifier("kyroPerformanceOverlayToggle")
                if performanceOverlayEnabled != KyroPerformanceDiagnostics.isEnabled {
                    Text("Restart Kyro to apply.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LiveTVAccent.primaryText)
                }
            } header: {
                Text("Performance")
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                Text(LiveTVDiagnosticsCopy.performanceOverlayNote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Button("Copy Playback and Sports Log") {
                    let log = KyroLifecycleJournal.contents()
                    UIPasteboard.general.string = log
                    let lines = log.split(separator: "\n").count
                    journalCopyStatus = lines == 0 ? "The log is empty." : "Copied \(lines) lines."
                }
                .accessibilityIdentifier("kyroCopyLifecycleLog")
            } header: {
                Text("Logs")
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                Text(journalCopyStatus ?? LiveTVDiagnosticsCopy.logNote)
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)

            #if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
            Section {
                Toggle("Use experimental SQLite guide", isOn: $sqliteStorageEnabled)
                    .foregroundStyle(Color.siloOnSurface)
                    .tint(.siloSwitchOn)
                if sqliteStorageEnabled != (service.activeEPGStorageMode == .sqlite) {
                    Text("Restart required to activate the selected backend.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LiveTVAccent.primaryText)
                }
            } header: {
                Text("INTERNAL TEST — EPG Storage")
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                Text("Currently active: \(service.activeEPGStorageMode == .sqlite ? "SQLite" : "Existing in-memory backend"). Changes apply after force-quitting and reopening Kyro. This control is included only in the owner’s experimental test build.")
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)

            Section {
                Toggle("Show Sports Match Report", isOn: $sportsDiagnosticsVisible)
                    .foregroundStyle(Color.siloOnSurface)
                    .tint(.siloSwitchOn)
                    .accessibilityIdentifier("kyroSportsDiagnosticsToggle")
            } header: {
                Text("INTERNAL TEST — Sports Diagnostics")
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                Text("Adds the Sports Match Report to Choose a Stream and Other Streams. Off by default so the normal interface stays clean.")
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)
            #endif
        }
        .settingsListChrome()
        .navigationTitle(LiveTVDiagnosticsCopy.title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }
}

/// Wording shared by the page and the Advanced & Diagnostics row.
enum LiveTVDiagnosticsCopy {
    static let title = "Live TV Diagnostics"
    static let rowSubtitle = "Performance overlay and playback log"
    static let searchTerms = ["live tv diagnostics", "performance overlay", "performance", "frame pacing",
                              "playback log", "sports log", "copy log", "lifecycle log", "debug"]
    static let performanceOverlayNote = "Shows frame pacing, main-thread stalls and guide update counts in a corner of the screen. Tap the overlay to copy a report; press and hold to reset it. Takes effect after force-quitting and reopening Kyro. Leave it off for normal use."
    static let logNote = "Picture in Picture, app, audio and Live TV session events, and why tennis statistics were or were not found. No stream, channel or account details. Paste it into a message after a test."
}
#endif
