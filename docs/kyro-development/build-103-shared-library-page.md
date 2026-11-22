# Build 103: shared Movies/Series page for Silo and IPTV

Build 102 failed on the iPhone: IPTV posters acknowledged taps but opened nothing, and the
Movies/Series layout put the source selector under the Kyro header with extra space below the
page chips. Build 103 fixes the causes and gives both sources one page structure.

## 1. Root causes

### IPTV posters never navigated (Builds 100, 101 and 102)

`KyroIPTVPosterCard` wrapped Silo's `MediaCard` in a view-destination `NavigationLink`. On iOS,
`MediaCard` with no `contentId` is itself `Button(action: action)` with `.buttonStyle(.plain)`, and
the IPTV card passed `action: {}`.

- Builds 100 and 101 added `.allowsHitTesting(false)` to the card. That removed the link's only
  label from hit testing, so nothing received the tap.
- Build 102 removed that modifier. The inner `Button` then won the tap: the plain style showed the
  press highlight and ran the empty action. The enclosing `NavigationLink` never fired.

The Build 98/99 page that did navigate used a custom poster view that was not a `Button`.

### Selector over the Kyro header, extra spacing

- The shell draws `KyroAppHeader` as an `.overlay` on the tab view. It adds no safe-area inset.
  Build 102 moved the page controls into each tab's scroll content and deleted the runway spacer
  that had kept them below the header, so scroll content started under the header.
- Each tab inserted the controls into its own stack, so the gap below the chips was the
  selector's 8 pt, the controls' 16 pt bottom padding and the stack spacing (16 or 24 pt): 40 to
  48 pt. Collections also padded the controls by 16 pt on every side, shifting them inward and
  down, and its loading, empty and error states (and Recommended's) dropped the controls
  entirely, so an empty Collections tab had no way back to Recommended.
- The controls kept the pinned-chrome glass (`PageChromeGlass` with `.ignoresSafeArea(edges:
  .top)` and `pageChromeBacking`) after they started scrolling, and the header skipped its own
  glass on Movies and Series because that panel used to supply it.

## 2. Architecture

- **Detail navigation.** IPTV cards are plain `MediaCard`s whose action calls
  `AppRouter.presentIPTVDetail(KyroIPTVDetailRequest)`. The router opens the same detail card
  Silo titles use (`ItemDetailSheet`), with `KyroIPTVVODDetailView` as the root, as Request
  details already do. Movies open the movie page; series open the series page with seasons and
  episodes. The page draws Silo's floating Close button (`PhoneDetailTopChrome`). IPTV cards stay
  sheets like Request cards (no split layout, never refit).
- **Playback.** Unchanged route: the detail page presents `PlayerView` with an
  `ExternalPlaybackRequest`. Start position, progress, titles, source label and the series
  resume episode now come from `KyroIPTVPlaybackPlan`.
- **Scroll container.** `LibraryPageScrollContainer` is the one vertical scroll view of every
  Movies/Series tab, for both sources and every state. It leads with the page controls and is the
  only reader of `libraryPageScrollControls`. `LibraryPageStatus` keeps Silo Library's error
  state under the controls on library pages and full screen elsewhere.
- **Pinned chrome.** Only the Kyro header is pinned. `LibrariesTabView` reserves its height once
  with `.safeAreaPadding(.top, runway)`; content starts below the header and scrolls under it.
  The controls carry no glass; the header draws its scroll glass on every tab.
- **Spacing.** One gap below the chips (8 pt selector inset + 8 pt), with no stack spacing above
  each tab's first row.
- **Source switching.** `LibraryPageSourceState` keeps the shown provider's page mounted while
  Silo is on screen and drops it when the provider changes or IPTV VOD is turned off. The IPTV
  subtree is keyed by the provider's ID.

Silo data loading (`BrowseViewModel`, Recommended and Collections models) and IPTV data loading
(`KyroIPTVBrowseModel`) stay separate.

## 3. Tests

Host (no Simulator), from `iosApp/`, with `Stubs.swift` holding `LiveTVError` and
`XtreamURLBuilder.apiURL` as in `Benchmarks/IPTVVODStoreBenchmark.swift`:

```sh
PLAT=$(xcrun --show-sdk-platform-path)
xcrun swiftc -D KYRO_VOD_HOST_TESTS -lsqlite3 -module-name KyroHostTests -parse-as-library \
  -F $PLAT/Developer/Library/Frameworks -I $PLAT/Developer/usr/lib -L $PLAT/Developer/usr/lib \
  -lXCTestSwiftSupport -framework XCTest -Xlinker -bundle \
  -Xlinker -rpath -Xlinker $PLAT/Developer/Library/Frameworks -Xlinker -rpath -Xlinker $PLAT/Developer/usr/lib \
  Stubs.swift iosApp/Kyro/IPTVVOD/XtreamVODModels.swift iosApp/Kyro/IPTVVOD/XtreamVODCatalogScanner.swift \
  iosApp/Kyro/IPTVVOD/XtreamVODCatalogStore.swift iosApp/Screens/Player/ExternalPlaybackDiagnostics.swift \
  iosApp/Kyro/IPTVVOD/KyroIPTVDetailRoute.swift iosApp/Screens/Browse/LibraryPageSourceState.swift \
  Tests/IPTVVODPlaybackAndBrowseTests.swift Tests/LibraryPageNavigationTests.swift \
  -o KyroHostTests.xctest/Contents/MacOS/KyroHostTests
xcrun xctest KyroHostTests.xctest   # the bundle also needs a minimal Contents/Info.plist
```

- `LibraryPageNavigationTests` (9): movie and series detail pages, page identity, start and
  resume positions, progress, player titles, series resume episode, source mounting and provider
  changes.
- `IPTVVODPlaybackAndBrowseTests` (9, Build 100): unchanged.
- `scripts/test_library_page_structure.py` (7 source guards): no `MediaCard` inside another tap
  target, IPTV cards route through the router, Silo routes intact, container ownership, header
  height reserved once with no page glass, Sources picker selected state. The tap-target guard
  flags the Build 102 card. These guard structure; they do not prove taps or layout.
- `IPTVDetailPresentationTests` (iOS target, needs Simulator or device): compiled, not run.

No rendered capture exists: these views need the iOS app environment, and Simulator use was not
approved.

## 4. iPhone acceptance checklist

1. Movies → IPTV source → tap a poster on Recommended, Library and a Collections category: the
   detail card opens; Close and pull-down dismiss it.
2. Movie detail → Play, and Resume / Start Over on a partly watched title.
3. Series → IPTV → poster → seasons and episodes → play an episode.
4. Silo Movies and Series: posters open details and play as before.
5. At the top of each tab, the selector sits just below the KYRO header with no overlap; the
   selector and chips scroll away; posters use the full height; only the header stays.
6. Collections with no collections, and a failed load: the chips are still there.
7. Switch Silo ↔ IPTV: each keeps its scroll position.
8. Sources popup: selected row has the stronger fill, checkmark and "Selected" value.
9. Live TV and Sports Hub unchanged.
