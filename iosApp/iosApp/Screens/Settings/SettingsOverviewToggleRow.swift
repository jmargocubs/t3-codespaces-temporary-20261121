#if os(iOS)
import SwiftUI

struct SettingsOverviewToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .center, spacing: 14) {
                SettingsIconTile(systemImage: systemImage)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.siloOnSurface)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .tint(.siloSwitchOn)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
#endif
