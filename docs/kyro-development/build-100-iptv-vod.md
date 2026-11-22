# Kyro iOS Build 100: IPTV VOD corrective pass

Baseline: Build 99 (`70728f09`). Visual and navigation baseline: Build 97 (`5177c2ee`, before any
IPTV VOD UI). No IPA was built for this pass.

## 1. Confirmed root causes

### Movies/Series UI (from the Build 98 device recording and the code)

| Symptom on device | Cause in Build 98/99 |
|---|---|
| "Silo" printed beside the KYRO wordmark and "IPTV" beside the search button | `KyroMediaSourceRoot` drew a segmented Silo/IPTV `Picker` in a `VStack` above the page. The unified shell draws the Kyro header as an overlay and only pages that leave `KyroShellHeader.runway` clear avoid it. The picker sat under the header, so its two labels landed inside the header row. Build 99 added a caption line to the same stack. |
| Two different Movies pages | IPTV selection swapped `LibrariesTabView` for `KyroIPTVVODCatalogView`: its own large "IPTV Movies" title, provider label, chip row, 190 pt `LazyImage` posters with an "IPTV" caption, and its own detail page with a system navigation title. |
| Competing navigation / search bars | `KyroIPTVVODCatalogView` used `.searchable`, which installs a system search bar in the shell's navigation stack, under the shell's own header and Search button. |
| Rebuild and lost scroll on every switch | `if isIPTVSelected { IPTV page } else { LibrariesTabView }` destroyed one page and rebuilt the other on every source change. The IPTV page's state (items, categories, scroll) lived in `@State` and reloaded from SQLite each time; Silo reloaded its libraries and shelves. |
| Pull-to-refresh re-imports 129k titles | `.refreshable` on the IPTV page called `service.refresh`, a full provider download. |

### IPTV VOD playback

Build 98 rejected `.mkv`/`.ts` before the player (extension allow-list). Build 99 removed that
and routed playback into Silo's `PlayerView` with a new `loadExternalURL`, which:

1. **Never recorded the load epoch.** It called `aetherPlaybackController.beginLoad(spec)` but
   not `activeAetherLoadEpoch = epoch`. `PlayerViewModel.handleAetherEvent` drops every event
   whose epoch is not `activeAetherLoadEpoch`, so playing state, clock, duration, track
   inventory, end of file and post-load failures were all discarded.
2. **Discarded the engine's typed failure.** Any throw from `finishLoad` became one sentence,
   "Kyro couldn't open this provider stream…". Aether's `PlaybackErrorInfo` (kind, error domain,
   HTTP status) was thrown away, so the device error could not say why.
3. **Ran Silo's recovery for a non-Silo stream** once events do flow: `.failure` goes to the
   Protocol V3 replan / stale-session renewal, `.firstFrame` to Silo startup and progress
   reporting, `.ended` to Next Up and reconnect logic, all keyed to a fake `iptv-vod-<uuid>`
   content ID.
4. **Left Live TV holding the provider connection.** Xtream accounts usually allow one stream.
   Live TV, a Sports inline player or a Live TV PiP window kept its connection open, and the
   panel refuses the second one (HTTP 403, or 509/503 "max connections").
5. **"Go Back" popped the detail page** instead of closing the player (`onDismissRequested`
   called the detail page's `dismiss`).

The exact failure the iPhone hit in Build 99 cannot be named from this Mac: no provider
credentials are available here, and Build 99 threw the typed error away. The candidates that
match "reaches Aether, then a playback error", in order of likelihood:

- **App Transport Security.** The shipped `Info.plist` allows only local networking
  (`NSAllowsLocalNetworking`). Aether reads HTTP(S) media through `URLSession`, which ATS
  governs. Xtream VOD URLs commonly redirect to a cleartext `http://` CDN host; ATS refuses that
  hop (`NSURLErrorDomain -1022`). Live TV can still work if its streams are served directly.
- **Connection limit** while Live TV or another device is streaming on the same account.
- **Codec/container** the device cannot decode (AVI/XviD, some MPEG-4 ASP). Matroska and MPEG-TS
  with H.264/HEVC are remuxed by Aether as for Silo direct play.

Build 100 makes the device report which one it is (section 4).

## 2. Before and after: screen hierarchy

Build 99, Movies tab with IPTV selected:

```
Shell overlay: KyroAppHeader (wordmark · search · remote · profile)
VStack                                 ← no header runway
├─ "Browsing IPTV · My Playlist"       ← under the header
├─ Picker(.segmented) [Silo | IPTV]    ← labels collide with wordmark/search
└─ KyroIPTVVODCatalogView              ← second page design
   ├─ .searchable (system search bar)
   ├─ "IPTV Movies" large title + provider Label
   ├─ category chip row, import button
   └─ LazyVGrid of 190 pt LazyImage posters + "IPTV" caption
      └─ NavigationLink → custom detail (system nav title, bordered buttons)
```

Build 100 (and Build 97 for Silo), any source:

```
Shell overlay: KyroAppHeader (wordmark · search · remote · profile)
LibrariesTabView                       ← Build 97 page, unchanged chrome
├─ safeAreaInset(top): runway · LibrarySelectorButton("IF Movies ▾" | "My Playlist ▾",
│                                      caption "Movies" | "IPTV · Movies")
│                      LibraryPageTabSelector [Recommended | Library | Collections]
└─ ZStack (both sources stay mounted; one visible)
   ├─ Silo tab content (LibraryRecommendedView / BrowseView / LibraryCollectionsView)
   └─ KyroIPTVLibraryContent
      ├─ Recommended: PosterShelf rails of MediaCard (Continue Watching, Recently Added,
      │               largest categories, See All → Library filtered)
      ├─ Library:     search field + CatalogControlChip category menu + PosterGridLayout grid of MediaCard
      └─ Collections: provider categories → opens Library on that category
LibraryPickerSheet ("Sources"): SILO libraries … / IPTV: My Playlist
Detail: PhoneDetailPageSurface + PhoneDetailHero + PhonePrimaryPillButton (+ episodes)
Player: PlayerView + ExternalPlaybackRequest (same HUD shows the title)
```

Removed or consolidated: the segmented Silo/IPTV picker, its "Browsing …" caption, the "IPTV
Movies/Series" large title, the provider label, the system `.searchable` bar, the "IPTV" card
caption, the IPTV-only detail layout, the player's overlay title (the player HUD now shows it),
and pull-to-refresh import.

## 3. Shared presentation components

| Component | Silo uses | IPTV now uses | Change |
|---|---|---|---|
| `LibrariesTabView` header, selector, tab bar | yes | yes | Accepts `LibraryAlternateSource`; selector and picker list it |
| `LibraryPickerSheet` / `LibraryPickerRowLabel` | yes | yes | Rows share one label view; "Silo" and "IPTV" sections |
| `MediaCard` | all poster rows/grids | every IPTV card | unchanged |
| `PosterGridLayout` | `CatalogGrid` | IPTV grid | Moved out of `CatalogGrid` unchanged |
| `PosterShelf` | — (MediaRow metrics) | IPTV shelves | New; MediaRow's iOS header/strip metrics. `MediaRow` itself is tied to Silo `SectionItem` IDs and tvOS focus, so it was not modified |
| `CatalogControlChip` | `BrowseView` sort/filter/shuffle | category menu | Moved out of `BrowseView` unchanged |
| `PhoneDetailPageSurface`, `PhoneDetailHero`, `PhonePrimaryPillButton`, `PhoneLabeledActionRow`, `PhoneSectionHeader` | movie/series/offline detail | IPTV detail | unchanged |
| `PlayerView` / `PlayerViewModel` / `AetherPlaybackController` | all playback | IPTV playback | External loads are epoch-tracked; Silo-only handlers skipped |

Data stays separate: `XtreamVODService`, `XtreamVODCatalogStore` and `XtreamVODItem` are untouched
as models; Silo's `Library`, `BrowseItem` and `SectionItem` are not used for IPTV.

## 4. Playback pipeline and diagnostics

- `PlayerViewModel.loadExternalPlayback(_:)` sets `activeAetherLoadEpoch`, establishes the
  load, adopts Aether's audio/subtitle inventory and plays. `handleExternalPlaybackEvent`
  handles first frame, end, failure and transport-restore failure for external loads; state,
  clock, duration, buffering and track events use the normal handlers.
- The URL is built by `XtreamURLBuilder.vodPlaybackURL`: `/movie/<user>/<pass>/<stream_id>.<ext>`
  for movies and `/series/<user>/<pass>/<episode_id>.<ext>` for episodes, credentials
  percent-encoded, container from the provider's `container_extension`.
- Before opening, the detail page stops Live TV if it is playing (`LiveTVService.endPlayback`).
- On failure the player shows a specific message at once from Aether's `PlaybackErrorInfo`, then
  runs `XtreamVODStreamProbe` once, after the engine has released the stream: a `Range:
  bytes=0-4095` GET that records redirect hops (status, https→http downgrade, host changed),
  final status, Content-Type, size, range support and the container's magic bytes, then
  cancels. The refined message and a credential-free code are shown under the error, written
  to the lifecycle journal (`iptv_vod` category) and logged.
- Retry reopens the same request at the current position. Closing the player saves position for
  Resume and Continue Watching.

Diagnostic code example: `reason=ats_blocked engine=sourceopenfailed code=url-1022 hops=1
downgrade=https_to_http redirect_host_changed=yes status=… container=…`.

| `reason=` | Message | Next step |
|---|---|---|
| `ats_blocked` | provider sent the video over insecure http | Needs a product decision: an ATS exception (see blockers) |
| `access_refused` | provider refused; another device streaming, or plan lacks VOD | Stop other streams; check plan |
| `connection_limit` | connection limit reached | Stop other streams |
| `not_found` | provider no longer has the title | Provider catalog is stale; update catalogs |
| `not_media` | web page instead of video | Subscription/portal issue |
| `unsupported_media` | format or codec not playable | Container/codec listed in the code |
| `network`, `tls_rejected`, `provider_error`, `unknown` | as named | — |

Nothing in the probe, code, journal or logs contains a URL, host, username, password or token.
The URL with credentials is passed only to Aether and the one probe request.

## 5. Setup flow

Live TV settings, "IPTV Movies & Series":
- **Show IPTV Movies & Series** toggle, off by default (unchanged preference key).
- When on: the selected Xtream provider's import status: Movies and Series counts, last import
  date, a single **Import Movies & Series** / **Update Movies & Series** button, per-catalog
  progress (`n of total`, stage text), failure message, and **Stop Import**.
- The text explains that both catalogs are imported with the login already saved for Live TV,
  and that turning VOD off keeps the catalogs, the provider and Live TV.
- The empty IPTV page shows the same status view and button.
- Nothing imports or deletes without that button: turning VOD on, opening the tab and pulling
  down do not download; turning it off does not delete.

## 6. Performance

Mac host measurements (Apple M2, optimized Swift, production `XtreamVODCatalogStore`, synthetic
129,100-movie catalog matching the device recording's size, 33 categories, 7 runs, median):

| Query | Build 99 use | Build 100 use | Median |
|---|---|---|---:|
| `categories()` `SELECT DISTINCT` | every search keystroke and category change | not used by the page | 25.0 ms |
| `categorySummaries()` `GROUP BY` | — | once per promoted catalog | 28.3 ms |
| `newest()` 20 | — | Recently Added | 0.10 ms |
| Whole Recommended load (count, summaries, newest, 8 category shelves) | — | once per catalog | 51.5 ms |
| `page()` first page, all / largest category | each reload | each grid identity change | 0.29 / 0.30 ms |
| `page()` FTS search | each debounced keystroke | each debounced keystroke | 7.8 ms |

Poster decode (600×900 JPEG, ImageIO, 60 runs): full decode as Build 99's `LazyImage` did,
7.3 ms and 2,109 KB per bitmap; thumbnail at the iPhone grid cell (558 px), 11.7 ms and 810 KB.
Decodes run off the main thread in Nuke either way; the gain is memory: Nuke's 256 MB decoded
cache holds about 3× as many posters (400 posters: 824 MB → 317 MB), so scrolling back re-decodes
less. IPTV cards now go through `AsyncImageView`'s shared pipeline, disk cache and lookahead.

View identity and work per switch:
- Source switch no longer rebuilds either page (both stay mounted; only opacity and hit testing
  change). Build 99 rebuilt the destination page and reloaded its data on every switch.
- IPTV state (tab, search, category, grid pages, shelves) lives in one `KyroIPTVBrowseModel` per
  provider and kind for the process.
- Grid reloads keep the visible page until the replacement arrives; stale loads are fenced by a
  generation counter; shelves reload only on `catalogRevision` (catalog promotion), not on
  watch-state saves.

Not measured: on-device frame times, main-thread hangs, memory and source-switch latency. They
need the iPhone or Instruments with a device.

## 7. Tests

Executed on the Mac (no Simulator):
- `Tests/IPTVVODPlaybackAndBrowseTests.swift`, 9 tests, compiled with the production VOD model,
  scanner, store and `ExternalPlaybackDiagnostics` under `-D KYRO_VOD_HOST_TESTS`: failure
  classification, probe refinement, credential-free codes, container sniffing, Content-Range,
  movie vs episode URL routing and rejection, title years, category shelves, newest/summary
  queries and provider isolation. 9 passed.
- `Tests/SettingsBackupUnifiedHostChecks.swift` (`-D KYRO_STANDALONE_TESTS`): 101 passed.
- The 129,100-row store measurement above (also checks counts and paging).

Run the IPTV host tests from `iosApp/` (stubs: `LiveTVError` and `XtreamURLBuilder.apiURL`, as in
`Benchmarks/IPTVVODStoreBenchmark.swift`):

```sh
PLAT=$(xcrun --show-sdk-platform-path)
xcrun swiftc -D KYRO_VOD_HOST_TESTS -lsqlite3 -module-name KyroHostTests -parse-as-library \
  -F $PLAT/Developer/Library/Frameworks -I $PLAT/Developer/usr/lib -L $PLAT/Developer/usr/lib \
  -lXCTestSwiftSupport -framework XCTest -Xlinker -bundle \
  -Xlinker -rpath -Xlinker $PLAT/Developer/Library/Frameworks -Xlinker -rpath -Xlinker $PLAT/Developer/usr/lib \
  Stubs.swift iosApp/Kyro/IPTVVOD/XtreamVODModels.swift iosApp/Kyro/IPTVVOD/XtreamVODCatalogScanner.swift \
  iosApp/Kyro/IPTVVOD/XtreamVODCatalogStore.swift iosApp/Screens/Player/ExternalPlaybackDiagnostics.swift \
  Tests/IPTVVODPlaybackAndBrowseTests.swift -o KyroHostTests.xctest/Contents/MacOS/KyroHostTests
xcrun xctest KyroHostTests.xctest   # bundle also needs a minimal Contents/Info.plist
```

### 7a. Compiled, not executed

- `Silo` scheme, Debug, `generic/platform=iOS`, `build-for-testing`, `-jobs 2`,
  `CODE_SIGNING_ALLOWED=NO`: **TEST BUILD SUCCEEDED** (379 s). This compiles the app and every
  iOS XCTest, including `IPTVVODFoundationTests`, the new tests, and the Live TV, Guide, Sports
  (NCAA basketball), backup and player suites. None were run: they need a Simulator.
- Same scheme with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) KYRO_LIVETV_100K_VALIDATION`,
  Debug `build`: **BUILD SUCCEEDED** (287 s); the flag appears in 38 compile commands.
- `SiloTV` from this branch: **fails** with 13 errors in four Live TV files not touched here
  (`LiveTVCategoryBrowser`, `LiveTVGuideView`, `LiveTVHomeContent`, `LiveTVBrowseModel`:
  iPhone-only modifiers). This is the known pre-existing state of `kyro/m1-rebrand`; tvOS
  builds from `kyro/tvos`. No error was reported in any file changed by this pass, which
  includes the shared `CatalogGrid`, `BrowseView`, `LibrariesTabView`, `PlayerView` and
  `PlayerViewModel`, but because the target failed this is not proof that tvOS links.

## 8. Visual verification

No rendered capture of the new screens was produced. The views depend on the iOS app
environment (router, shell header, Nuke pipeline, Live TV service); rendering them needs the
iOS Simulator or the device, and Simulator use was not approved. Compilation is not visual
proof. The hierarchy in section 2 is the intended result; section 9 is the device check.

## 9. Physical iPhone acceptance checklist

Movies and Series
1. VOD off: Movies and Series look exactly like Build 97; the selector lists Silo libraries only.
2. VOD on: the header row shows only KYRO, search, remote and profile. No "Silo"/"IPTV" text in it.
3. Tap the library name: the sheet is titled "Sources" with SILO libraries and IPTV: provider.
4. Choose the provider: selector reads "My Playlist ▾ / IPTV · Movies"; the same Recommended /
   Library / Collections bar remains; no second title or system search bar appears.
5. Recommended shows poster rails like Silo's (Recently Added, then categories); See All opens
   Library on that category.
6. Library: search filters as you type; the category chip filters; grid is three-up like Silo's.
7. Collections lists categories with counts; tapping one opens Library filtered to it.
8. Switch back to Silo: the Silo page is where you left it (tab and scroll); switch to IPTV again:
   same tab, search, category and scroll.
9. Series tab keeps its own source and state independently of Movies.

Detail and playback
10. IPTV detail looks like a Silo detail page (artwork, title, facts, white Play pill).
11. Play a movie (try one MP4 and one MKV): video plays, scrubber and duration move, audio
    tracks appear, Go Back returns to the detail page, and Play then says Resume.
12. Play an episode: the episode plays; the series' Play button resumes it later.
13. Start Live TV, then play an IPTV movie: Live TV stops and the movie opens.
14. If any title fails: write down the message and the grey code line under it.

Setup
15. Settings → Live TV: toggle text, counts, last import, Update button, progress, Stop Import.
16. Pull down on IPTV Movies: no import starts. Turn VOD off and on: the catalog is still there.

Regression
17. Silo movie and episode playback, Live TV, Guide, Sports (including NCAA basketball), and
    Settings backup export/import behave as in Build 99.

## 10. Remaining blockers

- **Real stream verification is outstanding.** No provider stream was played from this Mac.
- **If the code reads `reason=ats_blocked`**, playback needs an App Transport Security exception
  for media (for example `NSAllowsArbitraryLoadsForMedia` does *not* cover Aether's
  `URLSession` reader; a scoped `NSExceptionDomains` entry or `NSAllowsArbitraryLoads` would).
  That loosens a security setting and needs an explicit decision; it was not changed.
- Codecs that iOS cannot decode and Aether cannot bridge will still fail, with
  `reason=unsupported_media` and the container in the code. No second player was added.
- IPTV Picture in Picture restore after leaving the detail page is not specially handled.
