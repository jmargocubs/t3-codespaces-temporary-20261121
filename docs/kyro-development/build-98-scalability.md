# Kyro iOS Build 98 scalability status

Build 98 remains **in progress**. The iOS-only VOD port and source separation from commits
`d0642d4d` and `32631e1b` remain intact. VOD indexing and recovery are measured below;
the Live TV migration is not yet complete. Neither 100,000-channel Live TV readiness nor
real-device VOD capacities have been established.

## Architecture implemented

- VOD rows remain provider/kind/generation scoped in SQLite. A refresh stages a new generation
  in bounded batches, then switches the active generation transactionally. The previous
  generation remains readable if parsing, storage, cancellation, or promotion fails.
- VOD title search now uses an external-content FTS5 index with insert/update/delete triggers
  in the same SQLite transaction as catalog writes. Existing catalogs are rebuilt once under
  `user_version=2`. Queries join from the FTS index instead of scanning titles with `%LIKE%`.
  Search matches token prefixes; it no longer promises arbitrary mid-word substring matching.
- Browse-only pagination has generation-scoped sparse title checkpoints every 1,024 rows. Deep
  pages seek from the nearest checkpoint instead of offset-scanning the entire 400K-row index;
  duplicate-title boundaries are covered by host checks. Category and search pages still use
  OFFSET and need representative real-provider measurements.
- Opening or migrating the catalog database runs on a utility worker rather than the main actor.
  One in-flight open is shared among callers. Old and crash-orphaned generations are removed in
  cancellable 1,024-row batches, after promotion or before the next refresh. This makes the
  active-generation switch short; it does not make a full provider download incremental.
- Xtream `get_vod_streams` and `get_series` do not supply a reliable revision token in this
  client contract, so VOD refresh remains bounded full replacement. Import concurrency is one
  refresh pipeline at a time, with the existing streaming scanner and 1,024-row insertion batches.
- The default-off VOD preference, unified backup, Silo/IPTV source selection, provider-specific
  IDs and playback from the earlier milestones are unchanged.

## Synthetic Mac host benchmark

The benchmark compiles the **production** VOD model, scanner, and SQLite store using
`KYRO_VOD_HOST_TESTS`; only unrelated Live TV URL/error dependencies are stubbed. Fixtures use
deterministic numbered titles, 40 categories, no artwork or summaries, one provider and one
generation. Every run checks stored count, paging, search and provider isolation. A separate
host checks verify legacy-catalog FTS migration, duplicate upsert, interrupted-generation pruning,
FTS recovery on reopen and pagination across duplicate-title checkpoint boundaries.

Run without Simulator from the repository root:

```sh
swiftc -O -D KYRO_VOD_HOST_TESTS -lsqlite3 \
  iosApp/iosApp/Kyro/IPTVVOD/XtreamVODModels.swift \
  iosApp/iosApp/Kyro/IPTVVOD/XtreamVODCatalogScanner.swift \
  iosApp/iosApp/Kyro/IPTVVOD/XtreamVODCatalogStore.swift \
  iosApp/Benchmarks/IPTVVODStoreBenchmark.swift -o /tmp/kyro-vod-benchmark
BENCH_DIR=$(mktemp -d)
/tmp/kyro-vod-benchmark "$BENCH_DIR"
```

Measured on Apple M2, macOS 26.6, optimized Swift, SQLite WAL, with no Simulator. Times are
one run each, not p95; process peak RSS includes all sequential fixtures and is not per catalog.
The `sqlite_bytes` column measures the main DB file after closing, excluding WAL/SHM and
filesystem overhead. No real iPhone timings or memory measurements were collected.

| Kind | Rows | Import + index | Exact-title-prefix search | Category page | Page 200 | Final page | DB file | Process peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Movie | 100,000 | 2.863 s | 2 ms | <1 ms | <1 ms | <1 ms | 41.7 MB | 18 MB |
| Movie | 200,000 | 5.928 s | 4 ms | <1 ms | <1 ms | <1 ms | 83.3 MB | 19 MB |
| Movie | 400,000 | 12.719 s | 12 ms | <1 ms | <1 ms | <1 ms | 166.6 MB | 21 MB |
| Series | 50,000 | 1.396 s | 1 ms | <1 ms | <1 ms | <1 ms | 20.9 MB | 21 MB |
| Series | 100,000 | 2.837 s | 2 ms | <1 ms | <1 ms | <1 ms | 41.9 MB | 21 MB |
| Series | 200,000 | 5.949 s | 4 ms | <1 ms | <1 ms | <1 ms | 84.0 MB | 21 MB |

Provisional synthetic budgets: 400K movie import + index <30 s, indexed search <50 ms,
category/page query (including final page) <50 ms, main DB <250 MB and host process peak RSS <100 MB. These fixtures
meet those budgets, but do **not** validate provider JSON download/scan time, image load, deep
pagination, populated metadata, disk-full behavior, concurrent UI work, or iPhone memory.

## Live TV channel-store and iOS query integration (current milestone)

The iOS-only `LiveTVChannelCatalogStore` now provides a separate SQLite channel database;
VOD tables, identities, and lifecycle are unchanged. Rows are scoped by provider and import
generation. Imports commit in bounded batches; a count and contiguous-ordinal check gates a
single-transaction active-generation switch. Old and crash-orphaned rows can be pruned in
1,024-row cancellable batches. Source ordinals preserve provider order. An ordinal index pages
Guide rows, a category/ordinal index pages categories, FTS5 indexes name/category search, and
provider-scoped favorites survive a generation replacement. Individual channel lookup retains
guide ID, stream URL, and stream ID for future EPG/playback integration. A host correctness run
checks interrupted promotion, cancellation, provider ID collision, category replacement,
favorite persistence, guide ID association, and recovery on reopen. Each scale fixture also
checks final-channel URL/guide lookup, favorite retrieval, filtered result counts and the
bounded category-summary query used by the iOS Categories screen.

On iOS, Browse, direct Live TV search, favorites and Guide rows now request 200-channel pages
from the provider-scoped store. `LiveTVPagedChannelModel` keeps a bidirectional sliding window
of at most 1,000 channels, cancels stale requests, and rejects results after a provider or
catalog-revision change. Reaching either window edge loads the adjacent page and drops rows at
the opposite edge. Category selection uses one grouped SQLite summary per category rather than
scanning the catalog in Swift. Sports Hub's manual channel picker uses the same indexed search
and returns at most 40 matches. Existing installs without a valid SQLite generation retain a
bounded legacy-array fallback until a successful refresh creates the indexed catalog.

FTS initially took 8.8 seconds for a 100K search because SQLite chose the ordinal index and
probed the virtual table per row. Rewriting the predicate as a one-time rowid subquery reduced
that synthetic query to 14 ms. This is a query-plan fix, not an iPhone responsiveness claim.

The benchmark compiles the **production** channel store and bounded-batch importer with
`KYRO_CHANNEL_HOST_TESTS`; only `LiveTVChannel` is a matching host stub. It produces deterministic
numbered channels across 40 categories one 1,024-row batch at a time, so the scale fixture is not
itself a hidden full array. Import time includes staging, generation promotion and orphan cleanup.
After queries complete, the benchmark constructs the two largest remaining compact association
payloads (EPG guide ID/name keys and program-search ID/name/ordinal records). It never materializes
a compatibility `[LiveTVChannel]` catalog. It then releases those projections and samples resident
memory before and after closing SQLite.
Each size below ran in a fresh process. Results are one optimized-Swift run on Apple M2/macOS 26.6,
not p95. DB size is the closed main file, excluding WAL/SHM and filesystem overhead. The benchmark
does not include a real network response body or poster/EPG memory. No Simulator ran.

```sh
swiftc -O -D KYRO_CHANNEL_HOST_TESTS -lsqlite3 \
  iosApp/iosApp/LiveTV/LiveTVChannelCatalogStore.swift \
  iosApp/iosApp/LiveTV/LiveTVChannelCatalogImporter.swift \
  iosApp/Benchmarks/LiveTVChannelStoreBenchmark.swift -o /tmp/kyro-channel-benchmark
BENCH_DIR=$(mktemp -d)
/tmp/kyro-channel-benchmark "$BENCH_DIR" 100000
```

| Channels | Streaming import + index | Selective search | Broad search | Category/deep page | Final Guide/keyset page | EPG ID lookup | DB file | Streaming peak RSS | Peak with compact associations | Retained after SQLite close |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 40,000 | 1.875 s | 5 ms | 7 ms | <1 ms | <1 ms | <1 ms | 30.4 MB | 18 MB | 32 MB | 23 MB |
| 60,000 | 3.020 s | 8 ms | 11 ms | <1 ms | <1 ms | <1 ms | 45.7 MB | 18 MB | 36 MB | 28 MB |
| 80,000 | 3.590 s | 11 ms | 14 ms | <1 ms | <1 ms | <1 ms | 61.0 MB | 18 MB | 45 MB | 37 MB |
| 100,000 | 4.686 s | 14 ms | 18 ms | <1 ms | <1 ms | <1 ms | 76.3 MB | 18 MB | 53 MB | 45 MB |

Provisional channel-store budgets: 100K import/index <10 s, selective
search <50 ms, category and Guide page and EPG ID lookup <50 ms, main DB <100 MB,
host process peak RSS <100 MB. The isolated 100K fixture meets the provisional memory budget:
streamed staging peaks at 18 MB, compact EPG/program associations raise process peak RSS to
53 MB, and 45 MB remains after SQLite closes. The earlier compatibility-array fixture peaked at
89 MB and retained 81 MB; that allocation is no longer part of the successful SQLite path.
This is host evidence, not an iPhone budget guarantee. It does not
exercise a provider response body, mixed-content EPG,
long-running UI work, image loading, low storage, or real-device memory. The broad search uses
the common word “Channel” and returns the first 100 rows; representative query/category p95
still requires profiling. Main-thread stalls were not instrumented in this host benchmark;
the generic iOS build does not supply runtime responsiveness evidence. These are single-run
diagnostics, not stable p95s.

## Production consumer inventory and integration status

The dependency trace before migration found these full-array paths:

| Consumer | Current production path | Status |
|---|---|---|
| M3U/Xtream import | Provider response data is parsed directly into bounded SQLite staging batches | Migrated on iOS; the downloaded response `Data` remains one bounded-by-policy allocation |
| Refresh and snapshots | `LiveTVService.channelCatalogs`, whole-array JSON snapshot | Successful SQLite promotion publishes count/categories/revision only and clears the array; redundant JSON is removed after validation |
| Offline restore | Legacy JSON migration followed by protected SQLite generation | Valid SQLite is checked first and restored without materialization; legacy JSON decodes only when SQLite is unavailable |
| Browse/search/favorites | `LiveTVChannelSearchModel`, grouped arrays, `LiveTVChannelFiltering` | iOS production UI migrated to indexed count/page queries and a 1,000-row maximum window; legacy snapshot fallback remains array-backed |
| Categories | `LiveTVCategoryDirectory` scans full array | Grouped SQLite summaries; legacy fallback only |
| Guide/list/grid | `LiveTVGuideView.rows` holds filtered full array | 1,000-row sliding window plus stable-ID arbitrary-offset restoration |
| Sports Hub | detached full catalog index and manual-picker array | Manual search returns 40 rows; automatic matching retrieves at most 2,000 event-specific candidates using names, aliases, abbreviations and broadcasters |
| EPG | full-array filter construction, short-guide invalidation scans | Direct compact guide ID/name projection, indexed guide-ID lookup, and compact program-search associations; no stream/artwork/category values |
| Playback/player picker | `LiveTVPlayerView(channels:)`, full-array search | Stable provider/channel lookup for playback and a paged 1,000-row picker window |
| Home/favorites/history | full-array preview resolver and recent pruning | At most 12 favorite and 10 recent rows are resolved by indexed queries/IDs |
| Unified search | full in-memory channel index and tap-time array scan | FTS query returns at most 200 rows with a separate count; tap and program results resolve by stable ID |
| Provider switching | complete arrays retained for visited/selected providers | Fresh SQLite providers publish no array; fallback arrays are evicted when switching and cleared after successful promotion |

On iOS, `LiveTVService.refresh` now scans M3U bytes line by line or Xtream live-stream JSON one
top-level member at a time, stages at most 1,024 channels per store call, and promotes only a
validated generation. Provider order, stable IDs, duplicate rules and the 40K cap remain intact.
Cancellation or an invalid generation leaves the old generation active. A provider/source change
that races the promotion restores the prior active generation before orphan cleanup.
Provider removal deletes its channel rows. Offline restore checks the protected SQLite generation
before reading an existing redacted JSON snapshot; after the next successful promotion the protected Application
Support SQLite generation becomes the last-known-good snapshot and the redundant JSON file is
removed. SQLite is excluded from device backup and uses complete-until-first-authentication file
protection. Provider switching and cold offline restoration query the same last-known-good SQLite
generation. The synthetic Mac host check
executes bounded import, atomic replacement, late-promotion rollback, cancellation, provider
isolation, favorites, ordered multi-ID resolution, filtered counts, category summaries, EPG IDs,
compact associations, stable deep offsets and offline restore. Focused XCTest coverage was
compiled but not executed.

## Remaining Live TV limits and risks

Live TV remains limited to **40,000** channels. The normal successful SQLite path no longer retains
a selected-provider `[LiveTVChannel]`, but the production cap does not change in this milestone:

- Legacy JSON snapshots migrate safely, but a cold legacy restore still decodes its old whole-array
  file once when no valid SQLite generation exists. New successful imports clear that fallback and
  do not write another whole-array JSON snapshot.
- EPG refresh and program search still create all-row **compact** key/association projections.
  They intentionally omit stream URLs, artwork URLs, categories and full channel values, and the
  100K benchmark includes their memory, but a future direct SQLite-to-EPG join/index could reduce
  this further.
- Automatic Sports matching is bounded to 2,000 indexed candidates per event. Candidate terms cover
  full names, locations, nicknames, abbreviations, curated aliases and broadcasters, but real-provider
  naming quality still needs device/provider validation.
- The host benchmark is not an integrated app benchmark and cannot validate 100K scrolling,
  playback, PiP, EPG refresh or main-thread responsiveness on an iPhone.
- The SQLite channel catalog stores stream URLs, which may embed provider credentials. It now
  lives under protected Application Support and is excluded from backup. Verify protection and
  lifecycle on a device, and review
  whether URL encryption or ID-based reconstruction is required before expanding this path.

The architecture is ready for a dedicated 100K physical-iPhone validation build, but not for a
production cap raise. Device evidence must pass before changing the 40K limit.

## Validation and device acceptance

The generic iOS `build-for-testing` is a compile gate only. It does **not** run XCTest.
The Mac host benchmarks exercise VOD and channel-store SQLite correctness and synthetic scale.
The updated channel-store, unified-search, EPG-program-search, Sports matching, playback/picker,
Home-preview, paging/restoration, favorites and provider-switching XCTest paths were compiled but
not executed.
VOD preference, backup, import cancellation,
source separation, and the new Live TV service integration still need an approved runtime test
environment. No Simulator or IPA was used in this milestone.

Before accepting Build 98 on a physical iPhone: import real 100K-channel and large VOD provider
catalogs; observe import duration, app peak memory and UI frame stalls; rapidly switch category,
search, source and provider; play Live TV, movie and episode; verify EPG/current-next, favorites,
Silo history isolation, VOD disable/re-enable, backup preview/restore/Undo, interrupted import
recovery, low-storage failure and offline relaunch. Do not call the capacity targets supported
until those measurements pass.

## Verification pass (commit after 218b183b)

**Consumer coverage (read from source, not executed in-app).** Normal SQLite path, no
selected-provider `[LiveTVChannel]`: Browse/Guide/category/favorites paging, unified search, EPG
filter and associations (compact guide-ID/name projections read from SQLite), player picker
(`LiveTVPagedChannelModel`), Home previews (favorites page + ordered ID resolution), playback
lookup by stable ID, and deep restoration by ordinal anchor. There is no next/previous-channel
stepping in the player; the picker is the only channel switch.

**Defect found and fixed.** Sports matching retrieved candidates only by team words in the
*channel name*. Events carried by a generic network channel ("ESPN") that the *guide* lists were
no longer found, a regression from the old full-index match. `sportsChannelIndex` now also reads
the guide rows overlapping the event (`KyroSportsStreamMatcher.guideCandidateKeys`) and fetches
those channels with `LiveTVChannelCatalogStore.channels(providerID:guideKeys:)`, bounded to 400
rows. Limit: channels linked to the guide only by display name (no guide ID) are not retrieved this
way. The lookup uses `lower(trim(guide_id))`, which is an unindexed scan; it is allocation-free
and measured below.

**Remaining full-array paths.**
- Legacy JSON restore (one-time, no SQLite generation) and failed-store fallback: whole array, ≤ cap.
- `epgAssociationValues` / `programAssociations`: all-row compact projections (bounded EPG).
- Debug fixture route and `KyroSportsMatchReport` (internal builds) read `service.channels`
  (empty on the SQLite path); the `LiveTVPlayerView`/Sports hub call sites still pass
  `service.channels`, which is empty on the SQLite path and ignored by the SQLite picker.
- `LiveTVService.loadXtream` and the M3U array parser remain for the non-iOS and legacy paths.

**Fresh benchmark (this pass, new process per size, Apple M2).** Host benchmark of the production
store and importer; not an integrated app run.

| Channels | Import+index | Selective | Broad | Guide-key (Sports) | DB file | Streaming peak | Peak w/ associations | Retained |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 40,000 | 3.60 s* | 35 ms* | 8 ms | 28 ms | 30.4 MB | 17 MB | 31 MB | 23 MB |
| 60,000 | 2.66 s | 8 ms | 11 ms | 25 ms | 45.7 MB | 17 MB | 36 MB | 28 MB |
| 80,000 | 3.54 s | 11 ms | 14 ms | 36 ms | 61.0 MB | 18 MB | 45 MB | 36 MB |
| 100,000 | 4.46 s | 14 ms | 18 ms | 43 ms | 76.3 MB | 18 MB | 53 MB | 44 MB |

*The 40K run was the first after a fresh compile (cold file cache); it is not a regression
signal. Category/deep page, keyset page and EPG ID lookup were all under 1 ms. The 100 MB host
target holds. The benchmark's own preconditions (counts, ordering, isolation, favorites,
atomic replace, cancellation, offline restore) passed.

**Credential storage audit.**
- Protection: `completeUntilFirstUserAuthentication` on the directory, now also set explicitly on
  `channels.sqlite`, `-wal`, `-shm` (fixed; previously directory-only).
- Backup: excluded on the directory and now on each file (fixed likewise).
- Logging: no `print`/`NSLog`/logger calls in the store or importer; stream URLs are not logged there.
- Diagnostics/export: iOS diagnostics live under Caches; the settings backup reads its own
  subpaths. Nothing enumerates `Silo/LiveTV/ChannelCatalog`.
- Not fixed, recommended: Xtream URLs embed username and password. Resolving at playback time
  needs a store schema change (keep `stream_id`, rebuild the URL from the Keychain secret) and
  touches every `channel.streamURL` consumer. M3U URLs may carry provider tokens that cannot be
  reconstructed. At-rest risk is limited to a protected, non-backed-up file.

**Development-only 100K override.** `KYRO_LIVETV_100K_VALIDATION` (compile condition) raises the
cap to 100,000 and the playlist limit to 110 MiB. It is defined nowhere in `project.yml`; it
exists only if a validation build passes it as `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Default
builds keep 40,000 (`testProductionCapIsFortyThousandWithoutValidationFlag`, compiled not run).
The flagged variant itself has not been compiled yet.
