# Build 110 unified browsing

Movies and Series each have one Library grid that lists Silo and IPTV titles in a single
catalog-wide alphabetical order. A title that both sources confidently share appears once and
keeps every source. There is no Silo/IPTV selector on the Library tab.

## Architecture

The grid reads a local unified index stored in the existing IPTV VOD database
(`catalog.sqlite`, `XtreamVODCatalogStore`). The index adds tables; `vod_items`, its FTS index
and its triggers are unchanged, so Universal Search reads exactly what it read in Build 109.

| Table | Holds |
|---|---|
| `unified_iptv_keys` | Sort, match and entry keys for every row of every IPTV generation |
| `unified_silo_items` | Mirrored Silo cards (`BrowseItem` JSON) per identity scope, library and snapshot |
| `unified_silo_active` | The completed snapshot each library shows, with its sync time |

Code: `UnifiedCatalogIndex.swift` (store extension, paging, grouping, window, detail target),
`SiloCatalogMirror.swift` (sync engine and iOS adapter), `KyroUnifiedBrowseModel.swift`,
`KyroUnifiedBrowseView.swift`, `KyroAlternateSourcesInset.swift`.

### Keys and matching

`UnifiedCatalogKeys` folds case and diacritics with a fixed locale and drops a set-apart year
from the title. The sort key is that normalized title followed by the year; the match key is
the same pair and is empty when the year is unknown. Matching entries therefore share a sort
key and are adjacent in index order, so a page can always hold a complete match group.

A match group becomes one card only when each member comes from a different origin: at most one
Silo record and one record per IPTV provider. Any group with two records from one origin (two
Silo cuts, or a provider listing the same film twice) stays as separate cards. Titles without a
year never merge. This is the policy `UnifiedVODCatalog.aggregate` already applies to search.

### IPTV lifecycle

`XtreamVODService` builds a generation's keys after staging and before promotion, so a
generation becomes browsable and searchable in the same step and two generations of one
provider are never mixed. Discard, provider removal and orphan pruning delete keys with their
generation. Catalogs imported before Build 110 are indexed once, in the background, the first
time the grid opens (`ensureUnifiedKeys`). Disabling IPTV VOD or removing a provider removes its
titles from the grid.

### Silo mirror

`SiloCatalogMirror` walks each visible library of the grid's kind with Silo's title-sorted
catalog pages (60 per page, the size Silo's own grid uses) into a private snapshot.

- A snapshot becomes visible only when its walk finished for the same identity. The previous
  snapshot stays visible until then and is deleted in the same transaction that promotes the
  new one, so obsolete titles disappear only after a successful replacement.
- A rejected cursor (`startsOver`) discards the partial snapshot and restarts from the fresh
  first page, at most twice per sync.
- Failure, cancellation or an identity change discards the partial snapshot.
- A library is re-walked at most every 6 hours unless the viewer pulls to refresh.
- Rows are keyed by a one-way hash of server and profile. Queries read only the current scope.
  `AuthService.resetIdentityScopedStores` (every profile, account and server boundary) cancels
  walks and deletes all mirrored rows. Opening the grid also deletes other scopes' rows and
  libraries this profile can no longer see.

### Paging and the window

Pages are keyset reads on (sort key, match key, entry key) across both sources in one SQL
statement; SQLite orders at most two bounded candidate sets. A page always completes the match
group at its edge. The grid holds at most 600 cards, loads 100 at a time in either direction
and trims the far end by whole rows. Trimmed cards are re-read when the viewer scrolls back.
The boundary group is re-read on every page, so a group that changed since it loaded merges
instead of duplicating. The grid keeps its position by card identity (`scrollPosition`), and
when the index changes it rebuilds the window around the top visible card.

### Details

A Silo or matched card opens the existing Silo detail; an IPTV-only card opens the existing
IPTV detail. `ItemDetailPresentation.alternates` carries every other IPTV source, and a row under
the detail ("Also on IPTV · Provider") pushes that source's IPTV page inside the same card, so
Back returns to the matched title and closing the card returns to the same grid position. The
shared `ItemDetailView` and all playback routes are unchanged. The Build 111 Sources picker is
not part of this build.

## Recommended and Collections

These tabs stay Silo-only, with their library selector, recommendations, Continue Watching,
collections, favorites and progress behavior unchanged; the page labels their scope as Silo.

## Validation without a simulator

Host tests (run from `iosApp/`; `Stubs.swift` holds `LiveTVError`, `XtreamURLBuilder.apiURL`,
and minimal `BrowseItem` and `RequestMediaResult`, as in `Benchmarks/UnifiedCatalogIndexBenchmark.swift`):

```sh
PLAT=$(xcrun --show-sdk-platform-path)
xcrun swiftc -D KYRO_VOD_HOST_TESTS -lsqlite3 -module-name KyroHostTests -parse-as-library \
  -F $PLAT/Developer/Library/Frameworks -I $PLAT/Developer/usr/lib -L $PLAT/Developer/usr/lib \
  -lXCTestSwiftSupport -framework XCTest -Xlinker -bundle \
  -Xlinker -rpath -Xlinker $PLAT/Developer/Library/Frameworks -Xlinker -rpath -Xlinker $PLAT/Developer/usr/lib \
  Stubs.swift iosApp/Kyro/IPTVVOD/XtreamVODModels.swift iosApp/Kyro/IPTVVOD/XtreamVODCatalogScanner.swift \
  iosApp/Kyro/IPTVVOD/XtreamVODCatalogStore.swift iosApp/Kyro/IPTVVOD/UnifiedVODCatalog.swift \
  iosApp/Kyro/IPTVVOD/UnifiedCatalogIndex.swift iosApp/Kyro/IPTVVOD/SiloCatalogMirror.swift \
  iosApp/Screens/Player/ExternalPlaybackDiagnostics.swift \
  Tests/UnifiedCatalogIndexTests.swift Tests/IPTVVODPlaybackAndBrowseTests.swift \
  -o KyroHostTests.xctest/Contents/MacOS/KyroHostTests
xcrun xctest KyroHostTests.xctest   # bundle also needs a minimal Contents/Info.plist
```

Benchmark (100K IPTV titles from two providers, 40K shared, plus 10K Silo titles):

```sh
xcrun swiftc -O -D KYRO_VOD_HOST_TESTS -lsqlite3 -parse-as-library \
  iosApp/Kyro/IPTVVOD/XtreamVODModels.swift iosApp/Kyro/IPTVVOD/XtreamVODCatalogScanner.swift \
  iosApp/Kyro/IPTVVOD/XtreamVODCatalogStore.swift iosApp/Kyro/IPTVVOD/UnifiedVODCatalog.swift \
  iosApp/Kyro/IPTVVOD/UnifiedCatalogIndex.swift Benchmarks/UnifiedCatalogIndexBenchmark.swift \
  -o /tmp/kyro-unified-benchmark
/tmp/kyro-unified-benchmark "$(mktemp -d)"
```

Apple M2, macOS, optimized Swift, one run: key build for 100K IPTV rows 2.1 s; 10K Silo rows
staged and promoted 0.3 s; 65,000 cards (40,000 merged); full forward walk 1,117 pages in about
2.6–3.0 s, slowest page 6.6–39.6 ms (cold first reads); full backward restoration 1,123 pages,
slowest page under 7 ms; window never above 600 cards; peak RSS 34–37 MB. The unified tables add
about 43 MB to the database at this size (IPTV keys and their browse index about 38 MB, the 10K
Silo mirror about 5 MB).

## Known limitations

- Silo card badges (watched, progress, favorite) come from the last sync and can be up to six
  hours old until a pull to refresh; the Silo detail always shows live state.
- Leading articles are not ignored ("The Matrix" sorts under T).
- Same-provider duplicates (for example HD and 4K listings) stay separate cards.
- The unified index adds roughly 0.4 KB per IPTV title on disk.
