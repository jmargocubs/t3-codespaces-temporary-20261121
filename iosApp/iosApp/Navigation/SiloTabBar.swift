import SwiftUI

/// Silo's bottom tab bar: the system `TabView`, one `Tab` per destination,
/// each icon switching to its filled variant while selected, and the bar
/// minimizing on scroll where the OS supports it. The tint comes from the
/// environment.
///
/// Extracted from `MainTabView` so Kyro's Classic global shell and Silo's
/// native media shell use the same native bar rather than a copy.
/// In unified mode its fifth `KyroShellTab` is only a binding adapter to the
/// global selected-destination enum; the Live TV boolean is derived, not stored.
struct SiloTabBar<Item: Identifiable, Content: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selection: Item.ID
    let title: (Item) -> String
    let icon: (Item) -> String
    let selectedIcon: (Item) -> String
    @ViewBuilder let content: (Item) -> Content

    #if os(iOS)
    @Environment(\.kyroShellTab) private var shellTab
    #endif

    var body: some View {
        #if os(iOS)
        if let shellTab {
            barWithShellTab(shellTab)
        } else {
            bar
        }
        #else
        bar
        #endif
    }

    private var bar: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                Tab(
                    title(item),
                    systemImage: selection == item.id ? selectedIcon(item) : icon(item),
                    value: item.id
                ) {
                    content(item)
                }
            }
        }
        .siloTabBarMinimizeOnScroll()
    }

    #if os(iOS)
    private enum Slot: Hashable {
        case item(Item.ID)
        case shell
    }

    private func barWithShellTab(_ shell: KyroShellTab) -> some View {
        let index = KyroUnifiedNavigation.liveTVIndex(itemCount: items.count)
        let slot = Binding<Slot>(
            get: { shell.isSelected.wrappedValue ? .shell : .item(selection) },
            set: { slot in
                switch slot {
                case .shell:
                    shell.isSelected.wrappedValue = true
                case .item(let id):
                    shell.isSelected.wrappedValue = false
                    selection = id
                }
            }
        )
        return TabView(selection: slot) {
            ForEach(items.prefix(index)) { item in itemTab(item, slot: slot.wrappedValue) }
            Tab(shell.title, systemImage: shell.systemImage, value: Slot.shell) {
                shell.content()
                    .environment(\.kyroShellTab, nil)
            }
            ForEach(items.dropFirst(index)) { item in itemTab(item, slot: slot.wrappedValue) }
        }
        .siloTabBarMinimizeOnScroll()
        .onChange(of: selection) { _, _ in
            // The binding is derived from the same global store, so this is a
            // no-op adapter update after a media destination was selected.
            shell.isSelected.wrappedValue = false
        }
    }

    private func itemTab(_ item: Item, slot: Slot) -> some TabContent<Slot> {
        Tab(
            title(item),
            systemImage: slot == .item(item.id) ? selectedIcon(item) : icon(item),
            value: Slot.item(item.id)
        ) {
            content(item)
                .environment(\.kyroShellTab, nil)
        }
    }
    #endif
}
