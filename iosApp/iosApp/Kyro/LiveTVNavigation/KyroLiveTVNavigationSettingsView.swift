import SwiftUI

/// Live TV Settings → Navigation. Everything here is saved on this device
/// only; nothing is sent to the server or its profile settings.
struct KyroLiveTVNavigationSettingsView: View {
    @Bindable var store: KyroLiveTVNavigationStore
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                ForEach(KyroLiveTVNavigationStyle.allCases) { style in
                    Button {
                        store.preferences.style = style
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: symbol(for: style))
                                .font(.title3)
                                .foregroundStyle(KyroTheme.accentInk)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(style.title).foregroundStyle(KyroTheme.textPrimary)
                                    if style == .classic {
                                        Text("Default")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(KyroTheme.accentInk)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(KyroTheme.selectedFill, in: Capsule())
                                    }
                                }
                                Text(style.summary).font(.footnote).foregroundStyle(KyroTheme.textSecondary)
                            }
                            Spacer(minLength: 8)
                            if store.preferences.style == style {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(KyroTheme.accentInk)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(store.preferences.style == style ? .isSelected : [])
                    .accessibilityIdentifier("kyroNavStyle.\(style.rawValue)")
                }
            } header: {
                Text("Navigation Style")
            }

            Section {
                Picker("Starting Edge", selection: $store.preferences.startingEdge) {
                    ForEach(KyroNavigationEdge.allCases) { edge in Text(edge.title).tag(edge) }
                }
                Toggle("Allow Dragging", isOn: $store.preferences.allowsDragging)
                Button("Reset Position") {
                    store.preferences.resetPositions()
                }
                .accessibilityIdentifier("kyroNavResetPosition")
            } header: {
                Text("Position")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !store.preferences.style.isFloating {
                        Text("Position and Behavior apply to Adaptive Glass Dock and Thumb Fan.")
                    }
                    Text(store.preferences.allowsDragging
                         ? "Touch and hold the navigation button until it lifts with a blue ring, then drag it to any edge. It snaps to the nearest edge and remembers where you left it. Reset Position returns it to the starting edge."
                         : "Dragging is off, so the navigation stays where it is. Reset Position returns it to the starting edge.")
                    if let trace = store.lastHandleTrace {
                        Text("Last touch: \(trace.summary)")
                            .font(.caption2.monospaced())
                            .accessibilityIdentifier("kyroNavLastTouch")
                    }
                }
            }

            Section {
                Toggle("Collapse After Choosing", isOn: $store.preferences.autoCollapse)
                Picker("When Idle", selection: $store.preferences.idleBehavior) {
                    ForEach(KyroLiveTVNavigationIdleBehavior.allCases) { behavior in Text(behavior.title).tag(behavior) }
                }
                Toggle("Haptic Feedback", isOn: $store.preferences.hapticsEnabled)
                Toggle("Thumb Scrubbing", isOn: $store.preferences.thumbScrubbing)
            } header: {
                Text("Behavior")
            } footer: {
                Text("Thumb Scrubbing: slide across the open navigation, or drag straight out of the button, and lift your thumb to choose. A faded button stays tappable, and nothing fades while VoiceOver is on.")
            }

            Section {
                NavigationLink {
                    KyroLiveTVDestinationsSettingsView(store: store)
                } label: {
                    LabeledContent("Destinations", value: "\(store.preferences.visibleDestinations.count) shown")
                }
                .accessibilityIdentifier("kyroNavDestinationsLink")
            } header: {
                Text("Destinations")
            } footer: {
                Text("Choose which destinations appear and in what order.")
            }

            Section {
                Button("Reset Navigation to Defaults", role: .destructive) { isConfirmingReset = true }
                    .accessibilityIdentifier("kyroNavResetAll")
            }

            #if DEBUG || KYRO_UNIFIED_NAV_TOGGLE
            KyroUnifiedNavigationTestSection()
            #endif
        }
        .scrollContentBackground(.hidden)
        .background(KyroTheme.background)
        .tint(KyroTheme.accentInk)
        .navigationTitle("Navigation")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset navigation to its defaults?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset Navigation", role: .destructive) { store.resetAll() }
        } message: {
            Text("Style, position, behavior and destinations return to their original settings.")
        }
    }

    private func symbol(for style: KyroLiveTVNavigationStyle) -> String {
        switch style {
        case .classic: "dock.rectangle"
        case .glassDock: "rectangle.portrait.righthalf.inset.filled"
        case .thumbFan: "circle.circle"
        }
    }
}

/// Reorder destinations and choose which appear. Home is always shown: it is
/// the way back from every Live TV screen.
struct KyroLiveTVDestinationsSettingsView: View {
    @Bindable var store: KyroLiveTVNavigationStore

    var body: some View {
        List {
            Section {
                ForEach(store.preferences.order) { destination in
                    row(destination)
                }
                .onMove { source, offset in
                    store.preferences.move(fromOffsets: source, toOffset: offset)
                }
            } footer: {
                Text("Drag to reorder. Home is always shown so you can get back from anywhere in Live TV.")
            }

            Section {
                Button("Reset Destinations") { store.preferences.resetDestinations() }
                    .accessibilityIdentifier("kyroNavResetDestinations")
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(KyroTheme.background)
        .tint(KyroTheme.accentInk)
        .navigationTitle("Destinations")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Home has no switch rather than a disabled one, so it can still be reordered.
    @ViewBuilder
    private func row(_ destination: KyroLiveTVDestination) -> some View {
        if destination.isRequired {
            LabeledContent {
                Text("Always shown").font(.footnote).foregroundStyle(KyroTheme.textSecondary)
            } label: {
                label(destination)
            }
            .accessibilityIdentifier("kyroNavDestination.\(destination.rawValue)")
        } else {
            Toggle(isOn: Binding(
                get: { store.preferences.isVisible(destination) },
                set: { store.preferences.setVisible($0, for: destination) }
            )) {
                label(destination)
            }
            .accessibilityIdentifier("kyroNavDestination.\(destination.rawValue)")
        }
    }

    private func label(_ destination: KyroLiveTVDestination) -> some View {
        Label {
            Text(destination.title).foregroundStyle(KyroTheme.textPrimary)
        } icon: {
            Image(systemName: destination.systemImage).foregroundStyle(KyroTheme.accentInk)
        }
    }
}
