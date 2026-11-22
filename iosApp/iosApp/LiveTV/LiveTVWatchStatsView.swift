#if os(iOS)
import AetherEngine
import SwiftUI

/// Technical diagnostics shown from the shared player controls, refreshed only while visible.
/// Values the engine does not report on the current route read "Unavailable" rather than a guess.
struct LiveTVWatchStatsView: View {
    let monitor: LiveTVWatchStatsMonitor

    var body: some View {
        let stats = LiveTVWatchStats.make(monitor.sample)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(stats)
                ForEach(stats.sections) { section in
                    sectionView(section)
                }
                if !stats.sections.isEmpty {
                    Text("Unavailable means the player does not measure that value for this stream's playback route. Values refresh once per second while this panel is visible.")
                        .font(.caption)
                        .foregroundStyle(Color.siloSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("liveTVWatchStats")
    }

    private func header(_ stats: LiveTVWatchStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stats.isPlaying ? Color.green : Color.siloSecondaryText)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(stats.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Playback status, \(stats.status)")
            LiveTVQualityBadgeRow(badges: stats.badges)
        }
    }

    private func sectionView(_ section: LiveTVWatchStats.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(Color.siloSecondaryText)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row)
                    if index < section.rows.count - 1 { Divider().padding(.leading, 12) }
                }
            }
            .background(LiveTVSurface.row, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func rowView(_ row: LiveTVWatchStats.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.label)
                .font(.subheadline)
                .foregroundStyle(Color.siloSecondaryText)
            Spacer(minLength: 8)
            Text(row.value ?? LiveTVWatchStats.unavailable)
                .font(.subheadline.weight(row.value == nil ? .regular : .semibold))
                .monospacedDigit()
                .foregroundStyle(row.value == nil ? Color.siloSecondaryText.opacity(0.7) : Color.siloOnSurface)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// The Build 53 monitor remains the sole telemetry reader. No player surface or session is
/// created here; dismissing the sheet cancels its task and clears the last sample.
struct LiveTVStreamStatsSheet: View {
    let engine: AetherEngine
    @State private var monitor = LiveTVWatchStatsMonitor()

    var body: some View {
        NavigationStack {
            LiveTVWatchStatsView(monitor: monitor)
                .navigationTitle("Stream Information")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            while !Task.isCancelled {
                switch engine.playbackPhase {
                case .idle, .ended, .error:
                    monitor.reset()
                    return
                case .loading, .playing, .paused, .seeking, .rebuffering, .stalled:
                    monitor.refresh(from: engine)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .onDisappear { monitor.reset() }
    }
}

/// Small outlined capsules for the qualities the engine detected. Draws nothing when none are known.
struct LiveTVQualityBadgeRow: View {
    let badges: [LiveTVQualityBadge]

    var body: some View {
        if !badges.isEmpty {
            HStack(spacing: 4) {
                ForEach(badges) { badge in
                    Text(badge.text)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.85))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.siloOnSurface.opacity(0.35), lineWidth: 1))
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Detected quality: \(badges.map(\.accessibilityLabel).joined(separator: ", "))")
            .accessibilityIdentifier("liveTVQualityBadges")
        }
    }
}
#endif
