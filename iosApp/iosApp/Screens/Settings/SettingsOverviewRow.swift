#if os(iOS)
import SwiftUI

/// Settings destination row in the system Settings idiom: icon tile, title,
/// short description, and an optional current value. The containing
/// NavigationLink supplies its own chevron; plain buttons ask for one with
/// `showsChevron`.
struct SettingsOverviewRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var value: String? = nil
    var showsChevron = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A short value reads best at the trailing edge, like the system
    /// Settings app. A long one (a provider or server name) takes its own
    /// line under the description instead of squeezing the title.
    private var valueBelow: Bool {
        SettingsOverviewRowLayout.placesValueBelow(value, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIconTile(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.siloOnSurface)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let value, valueBelow {
                    Text(value)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let value, !valueBelow {
                Text(value)
                    .foregroundStyle(Color.siloSecondaryText)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            if showsChevron {
                SettingsRowChevron()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The full value is the accessibility value however it is laid out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityHint(subtitle)
    }
}

/// Where a row's current value goes. Pure, so the rule is testable.
enum SettingsOverviewRowLayout {
    /// Values longer than this leave the trailing edge for their own line.
    static let trailingValueLimit = 14

    static func placesValueBelow(_ value: String?, isAccessibilitySize: Bool) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return isAccessibilitySize || value.count > trailingValueLimit
    }
}

/// White glyph on a graphite rounded square — the leading icon of every
/// Settings overview row.
struct SettingsIconTile: View {
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.53, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Color.siloIconTile,
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
#endif
