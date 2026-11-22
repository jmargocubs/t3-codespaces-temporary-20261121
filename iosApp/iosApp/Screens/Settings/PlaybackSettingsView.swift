#if !os(tvOS)
import SwiftUI

/// Playback preferences sub-screen — a native grouped list in the
/// style of the iOS Settings app: plain rows, navigation-link pickers,
/// and footers for the fine print.
struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var spoilers = EpisodeSpoilerPreferences.shared
    @State private var showUseProfileSettingsConfirmation = false

    var body: some View {
        List {
            if viewModel.hasHeldPlaybackChanges {
                HeldSettingChangesSection(
                    retry: { await viewModel.retryHeldPlaybackChanges() },
                    discard: { await viewModel.discardHeldPlaybackChanges() },
                    message: viewModel.heldPlaybackChangesMessage
                )
            }
            if viewModel.playbackChangeWasRejected {
                rejectedChangeSection
            }
            qualitySection
            if viewModel.showsConnectionGroup {
                connectionSection
            }
            audioVideoSection
            behaviorSection
            // Hidden entirely on servers that do not serve the two keys.
            if spoilers.showsSettings {
                EpisodeSpoilerSettingsSection(store: spoilers)
            }
            SeekIntervalSettingsSections()
            advancedPlaybackEntry
            resetSection
        }
        .task { await spoilers.refresh() }
        // Reloads on another network, whose speed and limit differ.
        .task(id: BandwidthProbeScheduler.shared.connectionRevision) { await viewModel.loadPlaybackConnection() }
        .settingsListChrome()
        .navigationTitle("Playback")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .alert(
            SettingsViewModel.useProfileSettingsTitle,
            isPresented: $showUseProfileSettingsConfirmation
        ) {
            Button("Use Profile Settings", role: .destructive) {
                Task { await viewModel.resetPlaybackDeviceSettings() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.useProfileSettingsMessage)
        }
    }

    // MARK: - Quality

    /// Resolution and bitrate are two pickers: someone may want only 1080p on
    /// a fast connection, and a 1080p file can carry a higher bitrate than a
    /// 4K one. Each writes and clears only its own setting, as on the web.
    private var qualitySection: some View {
        Section {
            choiceRow("Resolution", .resolution, value: viewModel.qualityResolutionLabel, options: resolutionChoices)

            choiceRow("Maximum Bitrate", .maxBitrate, value: viewModel.maxBitrateLabel, options: maxBitrateChoices)

            // Three-way (labels fixed by the contract).
            if viewModel.showsBufferingQualityMode {
                choiceRow(
                    SettingsViewModel.bufferingQualityTitle,
                    .bufferingQualityMode,
                    value: viewModel.bufferingQualityMode.label,
                    options: BufferingQualityMode.allCases.map { SettingsChoice(id: $0.wireValue, label: $0.label) }
                )
            }

            // iPhone and iPad only. One preset list, since bitrate is what
            // matters on a data plan.
            #if os(iOS)
            choiceRow(
                "Cellular Quality",
                .cellularQuality,
                value: viewModel.cellularQualityLabel,
                options: cellularQualityChoices
            )
            #endif
        } header: {
            Text(PlaybackSettingsLayout.Group.streamingQuality.title)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(qualityFooterText)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    /// The quality note, the buffering description, then the cellular note,
    /// one line each.
    private var qualityFooterText: String {
        var lines = [viewModel.qualityFooterText]
        if viewModel.showsBufferingQualityMode {
            lines.append(SettingsViewModel.bufferingQualityDescription)
        }
        #if os(iOS)
        lines.append(SettingsViewModel.cellularQualityFooterText)
        #endif
        return lines.joined(separator: "\n")
    }

    // MARK: - Connection

    /// The speed the bandwidth probe measured on this connection, a test on
    /// demand, and what Auto plays as-is at that speed.
    private var connectionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(SettingsViewModel.connectionSpeedTitle)
                    .foregroundStyle(Color.siloOnSurface)
                // "measured 3 minutes ago" moves on while the page is open.
                TimelineView(.everyMinute) { context in
                    Text(viewModel.connectionSpeedLine(at: context.date))
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
            if viewModel.connectionSpeedSkippedText == nil {
                Button {
                    Task { await viewModel.testConnectionSpeed() }
                } label: {
                    Text(viewModel.isTestingConnectionSpeed
                         ? SettingsViewModel.testingSpeedLabel
                         : SettingsViewModel.testSpeedAction)
                }
                .disabled(viewModel.isTestingConnectionSpeed)
            }
        } header: {
            Text(SettingsViewModel.connectionSectionTitle)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            if let footer = connectionFooterText {
                Text(footer)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    /// The budget, then the last test's answer, one line each.
    private var connectionFooterText: String? {
        let lines = [viewModel.autoBudgetText, viewModel.connectionSpeedMessage].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Audio & Video

    private var audioVideoSection: some View {
        Section {
            choiceRow("Audio Language", .audioLanguage, value: audioLanguageLabel, options: audioLanguageChoices)

            Toggle("HDR", isOn: $viewModel.hdrEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Toggle("Dolby Vision", isOn: $viewModel.dolbyVisionEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
                .disabled(!viewModel.hdrEnabled)

            // iOS only: the engine's background policy is driven by the app
            // lifecycle notifications, which macOS does not post — a toggle
            // there would control nothing.
            #if os(iOS)
            Toggle("Background Playback", isOn: $viewModel.backgroundPlaybackEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
            #endif
        } header: {
            Text(PlaybackSettingsLayout.Group.audioVideo.title)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(SettingsViewModel.hdrFooterText)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Advanced Playback

    /// iPhone and iPad push the expert settings onto their own page so the
    /// everyday controls stay short; the Mac, which has no pushed pages here,
    /// shows the same sections inline.
    @ViewBuilder private var advancedPlaybackEntry: some View {
        #if os(macOS)
        PlaybackAdvancedSettingsSections(viewModel: viewModel)
        #else
        Section {
            NavigationLink {
                PlaybackAdvancedSettingsView(viewModel: viewModel)
            } label: {
                Text(PlaybackSettingsLayout.Group.advanced.title)
                    .foregroundStyle(Color.siloOnSurface)
            }
        } footer: {
            Text(PlaybackSettingsLayout.advancedEntryFooter)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
        #endif
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            // On / Off choices rather than switches: a switch has no third
            // position for going back to the profile's choice.
            choiceRow(
                "Auto-Play Next Episode",
                .autoPlayNext,
                value: viewModel.autoPlayNext ? "On" : "Off",
                options: onOffChoices
            )

            choiceRow(
                "Show Next Up",
                .nextUpPrompt,
                value: nextUpPromptOptions.first { $0.0 == viewModel.nextUpPromptSeconds }?.1
                    ?? "\(viewModel.nextUpPromptSeconds) seconds before end",
                options: nextUpPromptOptions.map { SettingsChoice(id: String($0.0), label: $0.1) }
            )

            // Three-way (labels fixed by the contract).
            choiceRow(
                "Skip Intros",
                .introSkipMode,
                value: viewModel.introSkipMode.label,
                options: IntroSkipMode.allCases.map { SettingsChoice(id: $0.wireValue, label: $0.label) }
            )

            choiceRow(
                "Skip Credits",
                .autoSkipCredits,
                value: viewModel.skipCredits ? "On" : "Off",
                options: onOffChoices
            )
        } header: {
            Text(PlaybackSettingsLayout.Group.episodeBehavior.title)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Refused change

    private var rejectedChangeSection: some View {
        Section {
            Button("OK") {
                Task { await viewModel.acknowledgeRejectedPlaybackChange() }
            }
        } header: {
            Text("Not Saved")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(SettingsViewModel.rejectedPlaybackChangeMessage)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Use Profile Settings

    private var resetSection: some View {
        Section {
            Button("Use Profile Settings", role: .destructive) {
                showUseProfileSettingsConfirmation = true
            }
        } footer: {
            Text("Removes the settings changed on this device, so it uses your profile's settings again.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: - Options

    /// A profile-backed row. The row always shows the value that applies,
    /// wherever it comes from; the choice list leads with "Use Profile
    /// Setting", checked while this device has no value of its own.
    private func choiceRow(
        _ title: String,
        _ setting: ProfileBackedPlaybackSetting,
        value: String,
        options: [SettingsChoice]
    ) -> some View {
        SettingsChoiceRow(
            title: title,
            value: value,
            options: [useProfileSettingChoice] + options,
            selection: Binding(
                get: { viewModel.playbackSelectionTag(setting) },
                set: { viewModel.selectPlayback($0, for: setting) }
            )
        )
    }

    private var useProfileSettingChoice: SettingsChoice {
        SettingsChoice(id: SettingsViewModel.useProfileSettingTag, label: SettingsViewModel.useProfileSettingLabel)
    }

    private var resolutionChoices: [SettingsChoice] {
        SiloQualityPresets.resolutionChoices.map {
            SettingsChoice(id: $0, label: SiloQualityPresets.resolutionLabel($0))
        }
    }

    private var maxBitrateChoices: [SettingsChoice] {
        [SettingsChoice(id: SettingsViewModel.noBitrateLimitTag, label: SiloQualityPresets.noBitrateLimitLabel)]
            + viewModel.maxBitrateChoicesKbps.map {
                SettingsChoice(id: String($0), label: SiloQualityPresets.bitrateLabel($0))
            }
    }

    #if os(iOS)
    private var cellularQualityChoices: [SettingsChoice] {
        // A pair no preset covers — set through the API, or written by a
        // client whose ladder has a rung this table does not — gets its own
        // entry describing what is actually stored, rather than the list
        // checking a preset the user never chose.
        var choices: [SettingsChoice] = []
        if !viewModel.usesProfileSetting(.cellularQuality), viewModel.cellularQualityPresetId == nil {
            choices.append(SettingsChoice(
                id: SettingsViewModel.customQualityTag,
                label: viewModel.cellularQualityLabel
            ))
        }
        return choices + SiloQualityPresets.all.map { SettingsChoice(id: $0.id, label: $0.label) }
    }
    #endif

    private var noAudioLanguageLabel: String {
        SettingPresentationMetadata.definitions[.playbackAudioLanguage]?.unsetLabel ?? "No preference"
    }

    private var audioLanguageLabel: String {
        let code = viewModel.preferredAudioLanguage
        guard !code.isEmpty else { return noAudioLanguageLabel }
        return viewModel.audioLanguageOptions.first { $0.code == code }?.label ?? code
    }

    private var audioLanguageChoices: [SettingsChoice] {
        let stored = viewModel.hasStoredNoAudioLanguagePreference
            ? [SettingsChoice(id: "", label: noAudioLanguageLabel)]
            : []
        return stored + viewModel.audioLanguageOptions.map { SettingsChoice(id: $0.code, label: $0.label) }
    }

    private var onOffChoices: [SettingsChoice] {
        [
            SettingsChoice(id: SettingsViewModel.onTag, label: "On"),
            SettingsChoice(id: SettingsViewModel.offTag, label: "Off"),
        ]
    }

    private var nextUpPromptOptions: [(Int, String)] {
        [
            (0, "At end"),
            (10, "10 seconds before end"),
            (30, "30 seconds before end"),
            (60, "1 minute before end"),
            (120, "2 minutes before end"),
        ]
    }
}

/// The order and wording of the Playback page. Presentation only: it names
/// where each existing control sits and owns no value or storage.
enum PlaybackSettingsLayout {
    enum Group: CaseIterable {
        case streamingQuality, audioVideo, episodeBehavior, playerControls, advanced

        var title: String {
            switch self {
            case .streamingQuality: "Streaming Quality"
            case .audioVideo: "Audio & Video"
            case .episodeBehavior: "Episode Behavior"
            case .playerControls: "Player Controls"
            case .advanced: "Advanced Playback"
            }
        }

        /// Row titles in display order. Rows that depend on the platform or
        /// the server are listed too; the page decides whether to show them.
        var controls: [String] {
            switch self {
            case .streamingQuality:
                ["Resolution", "Maximum Bitrate", "Cellular Quality", "Buffering Quality"]
            case .audioVideo:
                ["Audio Language", "HDR", "Dolby Vision", "Background Playback"]
            case .episodeBehavior:
                ["Auto-Play Next Episode", "Show Next Up", "Skip Intros", "Skip Credits",
                 "Blur unwatched episode images", "Hide unwatched episode descriptions"]
            case .playerControls:
                ["Skip Back", "Skip Forward"]
            case .advanced:
                ["Seek Cache", "Thumbnail Previews", "Buffer Ahead", "Lossless Multichannel Audio", "TrueHD Atmos and DTS:X",
                 "Deinterlacing", "Deinterlacing Field Rate", "Reset"]
            }
        }
    }

    static let learnedLimitGroupTitle = "Learned Connection Limit"
    static let spoilerProtectionTitle = "Spoiler Protection"
    static let videoSkipTitle = "Video Skip Intervals"
    static let audiobookSkipTitle = "Audiobook Skip Intervals"
    static let advancedEntryFooter = "Seek cache, thumbnail previews, buffering, lossless audio, and deinterlacing. The defaults suit most devices."
    static let advancedPageFooter = "Change these only to fix a playback problem on this device. Thumbnail Previews use Seekr when a key is configured; playback still works when they are off or unavailable."
    static let advancedAudioFooter = "If surround plays as stereo, turn off Lossless Multichannel Audio. With TrueHD Atmos and DTS:X on, those tracks keep their height channels but play as compressed audio."
}

#if os(iOS)
/// The pushed "Advanced Playback" page on iPhone and iPad.
struct PlaybackAdvancedSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            PlaybackAdvancedSettingsSections(viewModel: viewModel)
            SeekrSettingsSection()
        }
        .settingsListChrome()
        .navigationTitle(PlaybackSettingsLayout.Group.advanced.title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }
}

/// User-managed Seekr credentials. This is deliberately iOS-only and stores
/// nothing outside the app Keychain.
private struct SeekrSettingsSection: View {
    @State private var key = ""
    @State private var status: String?
    @State private var testing = false
    @State private var confirmRemoval = false

    private var hasStoredKey: Bool { SeekrCredentials.apiKey() != nil }

    var body: some View {
        Section {
            Toggle("Thumbnail Previews", isOn: Binding(
                get: { SeekrPreviewSettings.shared.previewsEnabled },
                set: { SeekrPreviewSettings.shared.setPreviewsEnabled($0) }
            ))
            .disabled(!hasStoredKey)
            .foregroundStyle(Color.siloOnSurface)
            .tint(.siloSwitchOn)

            if let status {
                Label(status, systemImage: status.hasPrefix("Connection successful") ? "checkmark.circle" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
            }

            SecureField(hasStoredKey ? "Enter a new API key to replace" : "Seekr API key", text: $key)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: key) { _, _ in status = "Connection not tested for this key." }

            Button("Save Key") {
                guard SeekrCredentials.store(key) else {
                    status = "Enter a valid API key first."
                    return
                }
                key = ""
                status = "Key saved securely. Connection not tested."
            }
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Test Connection") {
                testConnection()
            }
            .disabled(testing || (key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasStoredKey))

            if hasStoredKey {
                Button("Remove Key", role: .destructive) { confirmRemoval = true }
            }

            Link("Get a Seekr API Key", destination: URL(string: "https://seekr.tv")!)
                .font(.footnote)
                .foregroundStyle(Color.siloSecondaryText)

            if testing { ProgressView("Testing connection…") }
        } header: {
            Text("Seekr")
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text("Seekr thumbnail previews are optional and use your own API key. Playback and server thumbnails continue to work when Seekr is unavailable.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)
        .task {
            if !hasStoredKey { SeekrPreviewSettings.shared.setPreviewsEnabled(false) }
            status = hasStoredKey ? "Connection not tested on this device." : nil
        }
        .confirmationDialog("Remove Seekr API key?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                SeekrCredentials.clear()
                SeekrPreviewSettings.shared.setPreviewsEnabled(false)
                key = ""
                status = "Key removed."
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private func testConnection() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = candidate.isEmpty ? SeekrCredentials.apiKey() : candidate
        guard let value, !value.isEmpty else { return }
        testing = true
        status = nil
        Task {
            let valid = await SeekrClient(apiKeyProvider: { value }).validateKey()
            await MainActor.run {
                testing = false
                guard key.trimmingCharacters(in: .whitespacesAndNewlines) == candidate else { return }
                status = valid
                    ? (candidate.isEmpty ? "Connection successful for saved key." : "Connection successful for entered key. Save it to use previews.")
                    : "Connection failed. Check the key and try again."
            }
        }
    }
}
#endif

/// Seek cache, buffering, audio passthrough, deinterlacing, and the learned
/// connection limit. The bindings are the ones the Playback page used before.
struct PlaybackAdvancedSettingsSections: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section {
            Toggle("Seek Cache", isOn: $viewModel.seekCacheEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            #if !os(iOS)
            Toggle("Thumbnail Previews", isOn: $viewModel.seekrThumbnailPreviewsEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
            #endif

            Picker("Buffer Ahead", selection: $viewModel.bufferAhead) {
                ForEach(BufferAheadMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
        } header: {
            Text(PlaybackSettingsLayout.Group.advanced.title)
                .foregroundStyle(Color.siloSecondaryText)
        } footer: {
            Text(PlaybackSettingsLayout.advancedPageFooter)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)

        Section {
            Toggle("Lossless Multichannel Audio", isOn: $viewModel.losslessAudioEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)

            Toggle("TrueHD Atmos and DTS:X", isOn: $viewModel.trueHDAtmosEnabled)
                .foregroundStyle(Color.siloOnSurface)
                .tint(.siloSwitchOn)
        } footer: {
            Text(PlaybackSettingsLayout.advancedAudioFooter)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .listRowBackground(Color.siloGroupedCell)

        Section {
            Picker("Deinterlacing", selection: $viewModel.deinterlaceMode) {
                ForEach(DeinterlacePreference.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()

            Picker("Deinterlacing Field Rate", selection: $viewModel.deinterlaceFieldRate) {
                ForEach(DeinterlaceFieldRatePreference.allCases, id: \.self) { rate in
                    Text(rate.label).tag(rate)
                }
            }
            .foregroundStyle(Color.siloOnSurface)
            .settingsPickerStyle()
        }
        .listRowBackground(Color.siloGroupedCell)

        // The sentence wraps, so Reset takes its own row rather than sitting
        // under it inside the same cell.
        if let limit = viewModel.learnedConnectionLimitText {
            Section {
                Text(limit)
                    .foregroundStyle(Color.siloOnSurface)
                Button("Reset") {
                    Task { await viewModel.resetLearnedConnectionLimit() }
                }
            } header: {
                Text(PlaybackSettingsLayout.learnedLimitGroupTitle)
                    .foregroundStyle(Color.siloSecondaryText)
            } footer: {
                if let error = viewModel.learnedLimitResetError {
                    Text(error)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
            .listRowBackground(Color.siloGroupedCell)
        }
    }
}

struct SettingsChoice: Identifiable, Hashable {
    let id: String
    let label: String
}

/// A settings row whose trailing text is the value that applies, which a
/// native Picker cannot show once its selected option is "Use Profile
/// Setting". Looks like the navigation-link pickers beside it on iOS and a
/// menu picker on macOS.
struct SettingsChoiceRow: View {
    let title: String
    let value: String
    let options: [SettingsChoice]
    @Binding var selection: String

    var body: some View {
        #if os(macOS)
        LabeledContent(title) {
            Menu {
                Picker(title, selection: $selection) {
                    ForEach(options) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(value)
            }
            .fixedSize()
        }
        .foregroundStyle(Color.siloOnSurface)
        #else
        NavigationLink {
            SettingsChoiceList(title: title, options: options, selection: $selection)
        } label: {
            LabeledContent(title, value: value)
        }
        .foregroundStyle(Color.siloOnSurface)
        #endif
    }
}

#if !os(macOS)
/// The pushed choice list, in the style of the navigation-link picker it
/// stands in for: a checkmark on the selected row, and back on choosing.
struct SettingsChoiceList: View {
    let title: String
    let options: [SettingsChoice]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(options) { option in
                    Button {
                        selection = option.id
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.label)
                                .foregroundStyle(Color.siloOnSurface)
                            Spacer(minLength: 16)
                            if option.id == selection {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(option.id == selection ? .isSelected : [])
                }
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .navigationTitle(title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
    }
}
#endif
#endif
