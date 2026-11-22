# Build 104: IPTV playback, Sports Live Now, performance diagnostics

## 1. IPTV VOD playback

### Failure (Build 103, iPhone)

Every movie and episode stopped with "The provider sent this video over an insecure (http)
connection, which iOS blocks for this app." The diagnostic line on screen read:

```
reason=ats_blocked engine=sourceOpenFailed code=url-1004 hops=1 downgrade=https_to_http
redirect_host_change=yes container=unknown error=url-1022
```

The provider's stream URL is HTTPS. It answers with one redirect to a different host over plain
HTTP. Aether reads sources through `URLSession`, and the app's ATS policy is
`NSAllowsLocalNetworking` only, so that hop fails with `-1022`
(`NSURLErrorAppTransportSecurityRequiresSecureConnection`). The cause is confirmed by the probe's
transport error code, not inferred. Live TV is unaffected because its streams did not take that
redirect.

### Options considered

- `NSAllowsArbitraryLoadsForMedia`: covers AVFoundation only; Aether's `URLSession` reads would
  still fail.
- Per-domain ATS exceptions: the media host belongs to the user's provider and is unknown at build
  time.
- `NSAllowsArbitraryLoads`: works, but the app accepts `http` server URLs in many places (Silo
  servers, pairing, sign-in links, Live TV) and relies on ATS to refuse them off the local
  network. It would also be ignored while `NSAllowsLocalNetworking` is present.
- Aether has no cleartext option (`EngineTLS` covers certificates only).

### Repair

- `XtreamVODStreamRoute.resolve` runs before Play: one ranged request that follows the
  provider's redirects and stops at the first plain-HTTP hop to a non-local host without loading
  it. A route that stays HTTPS (or local) plays the provider URL directly, unchanged from Build
  103. If the check cannot reach the provider, it returns `direct` and the player reports the
  real error as before.
- `XtreamVODCleartextRelay` serves the other routes. Aether reads
  `http://127.0.0.1:<port>/v/<token>/stream.<ext>`, which local networking already permits, and
  the relay makes the provider request with Network.framework:
  - follows up to 5 redirects; HTTPS hops keep normal certificate validation
  - forwards the player's `Range`, `User-Agent` and other end-to-end headers, the origin's own
    `Host`, `Accept-Encoding: identity` and `Connection: close`
  - streams the body back with one 256 KB chunk in flight
  - listens on the loopback interface only and answers only tokens registered for a playback;
    a route is released when the player closes (8 kept at most)
  - logs only status, hop count and duration; no URL, host, path, query or credential
- `Info.plist` is unchanged.
- The player request comes from `KyroIPTVPlaybackPlan.request`; the failure probe now reads the
  URL the player reads.

## 2. Sports Live Now

### Cause

Live Now and a tap waited for `liveCatalogs`, set only after this session's full playlist
download, SQLite import, verification and history prune. The rule ("cached rows are not
playable", Build 42) was written for the JSON snapshot, which strips credentials. Since the
SQLite migration the restored generation keeps full stream URLs, and the Live TV tab already
plays those rows (`isPlayable` checks only the URL). With the 100K validation limit the import
alone is about 4.4 s on an M2, before any network time, on every cold launch.

### Measurements (M2 Mac, production SQLite store, 100,000 channels, 3 runs)

| Step | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| Import (old wait, excluding download) | 4,299 ms | 4,587 ms | 4,412 ms |
| Candidate search query | 19 ms | 18 ms | 18 ms |
| Guide-key channel lookup | 43 ms | 44 ms | 43 ms |

Command: `swiftc -O -D KYRO_CHANNEL_HOST_TESTS -lsqlite3 -parse-as-library
iosApp/LiveTV/LiveTVChannelCatalogStore.swift iosApp/LiveTV/LiveTVChannelCatalogImporter.swift
Benchmarks/LiveTVChannelStoreBenchmark.swift`, run with a fresh directory and `100000`.

### Repair

`hasSportsMatchableCatalog` accepts the restored SQLite generation as well as this session's
download, for Live Now, the tap's wait, the channel index and the manual picker. The JSON
snapshot path still needs a download. The due refresh still runs in the background; when it
finishes, the catalog revision changes and Live Now re-matches. Scores, schedules and news never
waited on this.

## 3. App-wide lag

### Measured on the Mac

IPTV catalog queries are not the cause. Recommended's whole overview (count, category summaries,
Recently Added, 8 shelves) on the production store, off the main thread:

| Catalog | Overview |
| --- | --- |
| 100,000 movies | 43 ms |
| 200,000 movies | 74 ms |
| 400,000 movies | 149 ms |
| 100,000 series | 38 ms |

It runs once per imported catalog. The VOD import runs only from its button.

### Not reproducible on the Mac

The app-wide lag needs the iPhone. The likeliest remaining candidate is the 100K playlist import
(about 4.4 s of CPU on an M2) running while the user browses. The Diagnostics overlay (Live TV
Settings → Diagnostics, relaunch) now reports:

- frame pacing per top-level section (Home, Movies, Series, Sports, Live TV)
- frame pacing while a Live TV catalog refresh runs, and the refresh count
- durations: Live TV catalog refresh, Sports Live Now ready (open to first answer), Sports event
  match, IPTV stream route check, IPTV overview, IPTV grid page

Tap the overlay to copy the report. No performance change was made without a measurement.

## 4. Tests

Host (swiftc, no Simulator): 31 tests (Build 100: 9, Build 103: 9, Build 104 relay and route:
10, performance tallies: 3). The relay tests use real loopback sockets: a redirect with a
query, a byte range, header forwarding, an unknown token (404), a redirect loop (508), a released
route (404) and a route check that stops at a remote HTTP hop without loading it.

Source guards: `scripts/test_build104_guards.py` (4), `scripts/test_library_page_structure.py`
(7).

## 5. iPhone checklist

1. IPTV movie: Play starts (the button shows "Starting…" briefly). Seek forward and back.
2. IPTV episode: Play from the series page and from an episode row; Resume after leaving.
3. Picture in Picture and leaving the player save progress.
4. Silo movie and episode playback unchanged.
5. Cold launch → Sports: Live Now leaves "Checking your channels…" within about a second, then
   updates once the background refresh finishes. Tap a live game: it plays.
6. Diagnostics overlay on: browse Home, Movies, Series, Sports and Live TV, then copy the report.
