#if !os(tvOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Column count and card width for a poster grid on iPhone, iPad and Mac.
///
/// Moved out of `CatalogGrid` unchanged so every poster grid in the Movies and Series pages,
/// Silo's library grid and the IPTV catalog grid, is laid out by the same code at the same
/// card-size preference. tvOS keeps its own focus-driven grid in `CatalogGrid`.
struct PosterGridLayout {
    var gridWidth: CGFloat
    var horizontalSizeClass: UserInterfaceSizeClass?
    var verticalSizeClass: UserInterfaceSizeClass?
    var isAccessibilitySize: Bool
    var posterSize: CardPosterSize
    /// Library grids stay three-up on iPhone even when the shared card preference is Large.
    var forcesThreeColumnsOnPhone: Bool

    static let rowSpacing: CGFloat = 12

    var columns: [GridItem] {
        if isAccessibilitySize {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                count: horizontalSizeClass == .regular ? 3 : 2
            )
        }
        if let fit = widthFittedPosterFit {
            return fit.columns
        }
        if usesThreeColumnPhoneLayout {
            return Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: 3
            )
        }
        return AdaptiveColumns.posters(
            for: horizontalSizeClass,
            posterSize: posterSize,
            spacing: 8
        )
    }

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var usesThreeColumnPhoneLayout: Bool {
        #if os(iOS)
        forcesThreeColumnsOnPhone && isPhone
        #else
        false
        #endif
    }

    /// Cards fill their column instead of sitting at the fixed phone width
    /// inside it: always on iPad, and on a phone once the grid is too wide for
    /// three-up posters. Nil otherwise and until the grid has been measured.
    private var widthFittedPosterFit: AdaptiveColumns.PosterGridFit? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            return AdaptiveColumns.widePhonePosterFit(
                containerWidth: gridWidth,
                posterSize: posterSize,
                verticalSizeClass: verticalSizeClass
            )
        }
        return AdaptiveColumns.widthFittedPosters(
            containerWidth: gridWidth,
            minimumCardWidth: AdaptiveColumns.tabletMinimumPosterWidth * posterSize.scale,
            spacing: AdaptiveColumns.tabletPosterSpacing
        )
        #else
        return nil
        #endif
    }

    /// MediaCard applies the global poster-size scale after its override. Undo
    /// that scale here, then cap the standard width to the measured grid cell.
    var cardWidthOverride: CGFloat? {
        #if os(iOS)
        if isAccessibilitySize {
            let fittedWidth = AdaptiveColumns.fittedPosterWidth(
                containerWidth: gridWidth,
                columnCount: columns.count,
                spacing: 8,
                maximumWidth: 240
            )
            return fittedWidth / posterSize.scale
        }
        if let fit = widthFittedPosterFit {
            return fit.cardWidth / posterSize.scale
        }
        // Phone cards shrink to their column rather than spilling into the
        // gaps, as they would in a window narrower than three standard
        // posters, such as the iPhone Duo's cover screen beside its status
        // column.
        guard isPhone else { return nil }
        let scale = posterSize.scale
        let fittedWidth = AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: columns.count,
            spacing: 8,
            maximumWidth: usesThreeColumnPhoneLayout
                ? SiloTheme.posterCardWidth
                : SiloTheme.posterCardWidth * scale
        )
        return fittedWidth / scale
        #else
        return nil
        #endif
    }

    /// Titles of the grid row holding `index`, so each card sizes its title to the row's tallest.
    static func rowTitles(at index: Int, columnCount: Int, titles: (Range<Int>) -> [String], count: Int) -> [String]? {
        #if os(iOS)
        guard columnCount > 0 else { return nil }
        let rowStart = index - index % columnCount
        let rowEnd = min(rowStart + columnCount, count)
        return titles(rowStart..<rowEnd)
        #else
        return nil
        #endif
    }
}
#endif
