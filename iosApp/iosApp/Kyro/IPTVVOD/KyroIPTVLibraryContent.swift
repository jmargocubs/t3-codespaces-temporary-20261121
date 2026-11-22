#if os(iOS)
import SwiftUI

/// The IPTV provider's catalog inside the shared Movies/Series page. `LibrariesTabView` supplies
/// the source selector and Recommended / Library / Collections bar; this view supplies only the
/// selected tab's content, in the same `LibraryPageScrollContainer` as Silo's tabs and built from
/// the same parts: `PosterShelf` rails of `MediaCard`s for Recommended, `PosterGridLayout` and
/// `MediaCard` for Library, and selector-style rows for Collections (the provider's categories).
/// Only data loading (`KyroIPTVBrowseModel`) and the detail and playback adapters
/// (`KyroIPTVDetailRequest`, `KyroIPTVVODDetailView`) are the provider's own.
struct KyroIPTVLibraryContent: View {
    let provider: LiveTVProvider
    @Bindable var model: KyroIPTVBrowseModel

    private let service = XtreamVODService.shared

    var body: some View {
        Group {
            if !model.hasLoadedOverview {
                LibraryPageScrollContainer {
                    PosterRowsSkeleton()
                }
            } else if !model.hasCatalog {
                LibraryPageScrollContainer {
                    KyroIPTVCatalogStatusView(provider: provider, emphasis: .page)
                        .padding(.horizontal, SiloTheme.padding)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                }
            } else {
                switch model.tab {
                case .recommended:
                    KyroIPTVRecommendedView(provider: provider, model: model)
                case .library:
                    KyroIPTVLibraryGridView(provider: provider, model: model)
                case .collections:
                    KyroIPTVCollectionsView(model: model)
                }
            }
        }
        .siloPageBackground()
        // Shelves and categories reload only when a catalog is promoted; Continue Watching
        // when watch state changes.
        .task(id: "\(service.catalogRevision):\(service.revision)") {
            await model.refreshOverviewIfNeeded()
        }
    }
}

// MARK: - Recommended

private struct KyroIPTVRecommendedView: View {
    let provider: LiveTVProvider
    let model: KyroIPTVBrowseModel

    var body: some View {
        LibraryPageScrollContainer(showsIndicators: false) {
            LazyVStack(spacing: SiloTheme.largePadding) {
                KyroIPTVImportBanner(providerID: provider.id)
                if !model.continueWatching.isEmpty {
                    PosterShelf(title: "Continue Watching", items: model.continueWatching) { item in
                        KyroIPTVPosterCard(item: item, providerName: provider.name)
                    }
                }
                ForEach(model.shelves) { shelf in
                    PosterShelf(title: shelf.title, items: shelf.items, onSeeAll: {
                        model.showCategory(shelf.id == "newest" ? nil : shelf.title)
                    }) { item in
                        KyroIPTVPosterCard(item: item, providerName: provider.name)
                    }
                }
            }
            .padding(.bottom, SiloTheme.largePadding)
        }
        .siloScrollEdgeEffect()
    }
}

// MARK: - Library

private struct KyroIPTVLibraryGridView: View {
    let provider: LiveTVProvider
    @Bindable var model: KyroIPTVBrowseModel

    var body: some View {
        LibraryPageScrollContainer {
            VStack(spacing: SiloTheme.padding) {
                KyroIPTVImportBanner(providerID: provider.id)
                searchField
                controlBar
                if model.gridHasLoaded, model.gridItems.isEmpty, !model.gridIsLoading {
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: model.query.isEmpty ? "No titles in this category" : "No results",
                        subtitle: "Try another search or category."
                    )
                    .frame(minHeight: 280)
                } else {
                    KyroIPTVCatalogGrid(
                        items: model.gridItems,
                        isLoading: model.gridIsLoading || !model.gridHasLoaded,
                        hasMore: model.gridHasMore,
                        providerName: provider.name,
                        onLoadMore: { Task { await model.loadMoreGrid() } }
                    )
                    .padding(.horizontal, SiloTheme.padding)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: model.gridIdentity) {
            // Type-ahead waits for a pause; the category or a cleared search loads at once.
            if !model.query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await model.refreshGridIfNeeded()
        }
    }

    /// The same field shape as Silo's catalog search, typing in place because the provider
    /// catalog is searched on the device.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.siloSecondaryText)
            TextField("Search \(provider.name)", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundColor(.siloOnSurface)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.siloSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.siloBody)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                .fill(Color.siloSurfaceVariant)
                .overlay(
                    RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                        .stroke(Color.siloOutline, lineWidth: 1)
                )
        )
        .padding(.horizontal, SiloTheme.padding)
    }

    private var controlBar: some View {
        HStack(spacing: 9) {
            Menu {
                Button {
                    model.category = nil
                } label: {
                    if model.category == nil { Label("All Categories", systemImage: "checkmark") }
                    else { Text("All Categories") }
                }
                ForEach(model.categories) { summary in
                    Button {
                        model.category = summary.name
                    } label: {
                        let title = "\(summary.name) (\(summary.count.formatted()))"
                        if model.category == summary.name { Label(title, systemImage: "checkmark") }
                        else { Text(title) }
                    }
                }
            } label: {
                CatalogControlChip(icon: "line.3.horizontal.decrease",
                                   text: model.category ?? "All Categories")
            }
            Spacer(minLength: 0)
            Text("\(model.totalCount.formatted()) titles")
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
        }
        .padding(.horizontal, SiloTheme.padding)
    }
}

/// `CatalogGrid`'s layout and cards for provider items: the same `PosterGridLayout`, row
/// spacing, skeletons, row-height title matching and next-page trigger.
private struct KyroIPTVCatalogGrid: View {
    let items: [XtreamVODItem]
    let isLoading: Bool
    let hasMore: Bool
    let providerName: String
    let onLoadMore: () -> Void

    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = PosterGridLayout(
            gridWidth: gridWidth,
            horizontalSizeClass: hSize,
            verticalSizeClass: vSize,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            posterSize: uiCustomization.cardPresentation.posterSize,
            forcesThreeColumnsOnPhone: true
        )
        let columns = layout.columns
        let widthOverride = layout.cardWidthOverride
        let loadMoreID = items.suffix(6).first?.id
        LazyVGrid(columns: columns, spacing: PosterGridLayout.rowSpacing) {
            if items.isEmpty && isLoading {
                ForEach(0..<(columns.count * 4), id: \.self) { _ in
                    PosterSkeletonCard()
                }
            }
            ForEach(KyroIndexedItems(items: items)) { entry in
                KyroIPTVPosterCard(
                    item: entry.item,
                    providerName: providerName,
                    cardWidthOverride: widthOverride,
                    rowTitles: PosterGridLayout.rowTitles(
                        at: entry.index, columnCount: columns.count,
                        titles: { range in items[range].map(\.title) }, count: items.count)
                )
                .frame(maxWidth: .infinity)
                .onAppear {
                    if entry.item.id == loadMoreID, hasMore { onLoadMore() }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }

        if isLoading && !items.isEmpty {
            ProgressView()
                .tint(.siloOnSurface)
                .padding()
                .frame(maxWidth: .infinity)
        }
    }
}

/// Positions without copying the item array, as `CatalogGrid` does.
private struct KyroIndexedItems: RandomAccessCollection {
    struct Entry: Identifiable {
        let index: Int
        let item: XtreamVODItem
        var id: String { item.id }
    }

    let items: [XtreamVODItem]
    var startIndex: Int { items.startIndex }
    var endIndex: Int { items.endIndex }
    subscript(position: Int) -> Entry { Entry(index: position, item: items[position]) }
}

// MARK: - Collections

/// The provider's categories, largest first. Choosing one opens it in Library, the way a Silo
/// collection narrows a library, without adding a navigation destination.
private struct KyroIPTVCollectionsView: View {
    let model: KyroIPTVBrowseModel

    var body: some View {
        LibraryPageScrollContainer {
            LazyVStack(spacing: 8) {
                ForEach(model.categories) { summary in
                    Button {
                        model.showCategory(summary.name)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.siloOnSurface.opacity(0.12))
                                Image(systemName: model.kind == .movie ? "film.fill" : "tv.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.siloOnSurface)
                            }
                            .frame(width: 40, height: 40)
                            Text(summary.name)
                                .font(.siloHeadline)
                                .foregroundColor(.siloOnSurface)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(summary.count.formatted())
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.siloSecondaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                                .fill(Color.siloSurfaceElevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                                        .stroke(Color.siloOutline, lineWidth: 1)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.bottom, SiloTheme.largePadding)
        }
    }
}

// MARK: - Card

/// Silo's `MediaCard` for a provider title. `MediaCard` is the button: its action opens the title
/// in the app's detail card through the router, exactly as a Silo poster opens its title (see
/// `KyroIPTVDetailRequest` for why a `NavigationLink` around the card never fired).
struct KyroIPTVPosterCard: View {
    let item: XtreamVODItem
    let providerName: String
    var cardWidthOverride: CGFloat? = nil
    var rowTitles: [String]? = nil

    @Environment(AppRouter.self) private var router

    var body: some View {
        MediaCard(
            title: item.title,
            posterUrl: item.poster ?? "",
            mediaType: item.kind == .movie ? "movie" : "series",
            year: XtreamVODTitle.year(in: item.title),
            action: {
                router.presentIPTVDetail(KyroIPTVDetailRequest(item: item, providerName: providerName))
            },
            cardWidthOverride: cardWidthOverride,
            rowTitles: rowTitles
        )
    }
}

// MARK: - Import status

/// A slim progress line while this provider's catalogs are being updated in the background.
private struct KyroIPTVImportBanner: View {
    let providerID: UUID
    private let service = XtreamVODService.shared

    var body: some View {
        if service.isRefreshing, let progress = service.progress, progress.providerID == providerID {
            KyroIPTVImportProgressRows(progress: progress)
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)
        }
    }
}
#endif
