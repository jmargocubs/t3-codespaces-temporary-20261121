# Kyro iOS settings backup coverage audit

Audit date: 2026-11-18. Baseline: Build 93 source on `kyro/m1-rebrand`. **Audit only; no behavior, schema, data, or IPA changed.** The accepted iPhone flow is not a claim that every preference is covered.

## Counting and evidence

The unit below is one independently user-editable persisted preference, not one Swift property, one channel, or one subtitle-style subfield. A composite editor persisted as one atomic setting (card presentation, subtitle appearance, menu order, or a category's pin list) counts once. An effective server value and its local cache count once, not twice. Runtime-only filters, histories, diagnostics, migration markers, and generated contract keys without an iOS editor are not counted. A conditional row counts if it is available on a supported server/device. `F` = exported, compared, selectively restored and undoable through the production store; `P` = backed up but with a qualification; `M` = missing, eligible in principle; `D` = needs a product/identity decision; `X` = intentionally excluded; `R` = registry-only flag/inert setting, not counted as a user preference; `C` = contract-only candidate, not counted. `Live` means the owning observable store or `@AppStorage` should repaint; `reload` means explicit refresh/invalidation is needed; `N/A` means not restored. The restore notification currently has **one** consumer, `LiveTVCategoryBrowser`; it is not a general app refresh bus.

Storage abbreviations: `UD` = `UserDefaults`; `SD` = `SharedDefaults`; `API` = canonical Silo settings API with a scope; `UD+API` = local cache backed by the API. Unless stated otherwise all rows persist across launches (`Y`). Defaults are source/contract defaults, not merely the value initially shown while an async read is pending. `—` for a conditional server default means the effective manifest value must be queried; it must not be inferred from a cache. Source anchors: [backup registry](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupLiveRegistry.swift), [codec](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift), [restore](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift), [model](../../iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupModel.swift), [iOS Settings](../../iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift), [contract keys](../../iosApp/iosApp/Networking/SettingKeys.generated.swift).

**Inventory: 74 unique persistent, user-editable preferences: 16 F, 1 P, 43 M, 7 D, 7 X.** Twelve registry-only entries (`R`) and four contract/read-only candidates (`C`) are listed for transparency but excluded from that total. Build 93 registers **29** entries, but only **17** correspond to a currently exposed production user preference. The conservative eligible denominator is **60** (`F + P + M`), excluding 7 decisions and 7 intentional exclusions. Fully supported coverage is **16/60 = 26.7%**; counting the partial entry as present gives **17/60 = 28.3%**. The denominator will change after product decisions. This is source-level coverage, not an end-to-end test result for all 29 entries.

## Complete preference inventory

The `Key / field` column names the production key or canonical setting, **not** the backup-file ID. For the supported rows the backup ID is usually the same spelling as the label's group prefix; the exact mapping is in the registry. `compare/apply` is `yes` for F/P because both use the registered getter/setter. `no` means Build 93 neither exports nor compares/applies it. `P` explains the limitation in Risk. The recommendation column is the proposed disposition, not a change made by this audit.

| Setting | Screen / location | Key / field; storage; default; persists | Backup export / compare+apply | Runtime after restore | Recommendation | Risk |
|---|---|---|---|---|---|---|
| Fourth navigation tab | Settings → Navigation | `kyro.navigation.global.v1.fourthTab`; UD Codable; Sports; Y | F / yes | Live | Keep default | Low |
| Category layout | Live TV → Categories | `kyro.liveTV.categoryPreferences.build78.appearance`; UD; Hybrid; Y | F / yes | reload | Keep default | Low |
| Category grouping | Live TV → Categories | same prefix `.grouping`; UD; Provider Order; Y | F / yes | reload | Keep default | Low |
| Watch-screen guide layout | Live TV → Watch / Guide | `liveTV.watchGuide.style.v1`; UD / AppStorage; List; Y | F / yes | Live | Keep default | Low |
| Soccer extra statistics | No production control; internal Sports flag | `kyro.sports.theSportsDBSupplement.enabled`; UD; on; Y | R / yes | Next read | Remove from future default export | Not user-configurable; backup can create/restore an internal override |
| WTA match statistics | No production control; internal Sports flag | `kyro.sports.wtaMatchStats.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| Tennis news | No production control; internal Sports flag | `kyro.sports.tennisNews.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| ATP match statistics | No production control; internal Sports flag | `kyro.sports.tennisMyLifeStats.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| Tennis player info | No production control; internal Sports flag | `kyro.sports.tennisPlayerInfo.enabled`; UD; on; Y | R / yes | Next read | Same | Same |
| Download quality | Downloads & Storage | `downloads.preferredFormat`; UD via `DownloadSettings`; original; Y | P / yes | Live | Keep; fix fidelity | Registry maps an unrecognized stored format to `original`, so export can silently replace a current value |
| Wi-Fi-only downloads | Downloads & Storage | `downloads.wifiOnly`; UD; true; Y | F / yes | Live | Keep default | Low |
| Delete after watching | Downloads & Storage | `downloads.defaultDeleteWatched`; UD; false; Y | F / yes | Live | Keep default | New-subscription default only |
| Default storage cap | Downloads & Storage | `downloads.defaultMaxStorageGB`; UD; 0/unlimited; Y | F / yes | Live | Keep default | New-subscription default only |
| Downloads sort order | Downloads manager | `downloads.sortOption`; UD; largest first; Y | F / yes | Live | Keep default | Low |
| Keep watched downloads | Downloads & Storage | `downloads.keepWatchedDownloads`; UD; false; Y | F / yes | Live | Keep default | Low |
| Simultaneous downloads | Downloads & Storage | `downloads.simultaneousDownloads`; UD; 2; Y | F / yes | Live | Keep default | Device throughput varies |
| Buffer ahead | Advanced Playback | scoped `player.bufferAhead`; UD via `PlayerSettings`; Automatic; Y | F / yes | Live next playback | Keep optional/device | Disk/performance |
| Lossless multichannel bridge | Advanced Playback | scoped `player.losslessAudioEnabled`; UD; true; Y | F / yes | Live next playback | Keep optional/device | Hardware/audio path |
| Background playback / PiP policy | Playback | scoped `player.backgroundPlaybackEnabled`; UD; true; Y | F / yes | Live next lifecycle | Keep optional/device | PiP device availability checked |
| Deinterlacing mode | Advanced Playback | scoped `player.deinterlaceMode`; UD; Automatic; Y | F / yes | Live next playback | Keep optional/device | Hardware path |
| Deinterlacing field rate | Advanced Playback | scoped `player.deinterlaceFieldRate`; UD; Full Motion; Y | F / yes | Live next playback | Keep optional/device | Hardware path |
| TrueHD Atmos/DTS:X heights | Advanced Playback | scoped `player.trueHDAtmosEnabled`; UD; true; Y | F / yes | Live next playback | Keep optional/device | Audio capability |
| Backup's global navigation style | No production control | `kyro.navigation.global.v1.style`; UD Codable; Classic; Y | R / yes | No active UI | Stop exporting; retain old-file decoder | Wrong store for floating-navigation editor |
| Backup's global starting edge | No production control | same record `.startingEdge`; UD; Right; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global idle behavior | No production control | same record `.idleBehavior`; UD; Collapse; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global auto-collapse | No production control | same record `.autoCollapse`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global haptics | No production control | same record `.hapticsEnabled`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global thumb scrubbing | No production control | same record `.thumbScrubbing`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Backup's global drag permission | No production control | same record `.allowsDragging`; UD; true; Y | R / yes | No active UI | Same | Wrong store |
| Live TV floating navigation style | Live TV → Navigation (non-unified/iPad) | `kyro.liveTV.navigation.v1.style`; UD Codable; Classic; Y | M / no | Live | P2/device | Exposed editor writes legacy store, not backup's global store |
| Live TV floating starting edge | Same | same record `.startingEdge`; UD; Right; Y | M / no | Live | P2/device | Device geometry |
| Live TV floating idle behavior | Same | same record `.idleBehavior`; UD; Collapse; Y | M / no | Live | P2/device | Low |
| Live TV floating auto-collapse | Same | same record `.autoCollapse`; UD; true; Y | M / no | Live | P2/device | Low |
| Live TV floating haptics | Same | same record `.hapticsEnabled`; UD; true; Y | M / no | Live | P2/device | Low |
| Live TV floating thumb scrubbing | Same | same record `.thumbScrubbing`; UD; true; Y | M / no | Live | P2/device | Low |
| Live TV floating drag permission | Same | same record `.allowsDragging`; UD; true; Y | M / no | Live | P2/device | Low |
| Profile selection behavior | General | `profileLaunchState.v1.behavior`; SD Codable; Automatic; Y | M / no | reload | P0 portable behavior only | Must not include remembered profile ID or account epoch |
| Show advisory age | General | `catalog.show_advisory_age` profile API; false; Y | M / no | reload | P1 profile group | Server contract/version and profile identity |
| Media card presentation (preset, poster size, captions) | Interface | `ui.card_presentation`; API + scoped SD cache; standard; Y | M / no | reload | P0 profile/family group | Atomic composite; inherited vs explicit and sync conflicts |
| Primary menu order and visible shortcuts | Interface | `nav.primary_menu` + `nav.shortcuts`; API + scoped SD cache; contract layout; Y | M / no | reload | P0, two atomic records | Contains library IDs; resolve against destination catalog |
| Show title art | Interface | `ui.title_art`; profile/profile_device API + cache; on; Y | M / no | reload | P1 | Preserve apply-to-all scope semantics |
| Theme music enabled | Interface | `ui.theme_music_enabled`; profile_device API; off; Y | M / no | reload | P1 | Server capability |
| Loop theme music | Interface | `ui.theme_music_loop`; profile_device API; off; Y | M / no | reload | P1 | Server capability |
| Blur unwatched episode images | Playback | `catalog.hide_unwatched_episode_images`; profile API + cache; false; Y | M / no | reload | P0 | Profile-scoped, server revision gate |
| Hide unwatched episode descriptions | Playback | `catalog.hide_unwatched_episode_overviews`; profile API + cache; false; Y | M / no | reload | P0 | Profile-scoped, server revision gate |
| Streaming resolution | Playback | `playback.preferred_quality`; profile_device API + scoped UD cache; auto; Y | M / no | reload | P0 | Must preserve inherited/explicit state |
| Maximum bitrate | Playback | `playback.max_bitrate_kbps`; profile_device API + cache; unset; Y | M / no | reload | P0 | Distinct axis; no compound overwrite |
| Lower quality when buffering | Playback | `playback.buffering_quality_mode`; profile_device API + cache; contract default; Y | M / no | reload | P1 | Contract revision gate |
| Cellular quality | Playback | `playback.cellular_preferred_quality` and `.cellular_max_bitrate_kbps`; profile_device API + cache; 720p/2000 Kbps; Y | M / no | reload | P1, atomic pair | Device/network applicability |
| Preferred audio language | Playback | `playback.audio_language`; profile_device API + cache; none; Y | M / no | reload | P1 | Effective value can mask scope |
| HDR | Playback | `player.hdr_enabled`; profile_device API + cache; true; Y | M / no | reload | P1/device | Hardware applicability |
| Dolby Vision | Playback | `player.dolby_vision_enabled`; profile_device API + cache; true; Y | M / no | reload | P1/device | Depends on HDR |
| Seek cache | Advanced Playback | `player.seek_cache_enabled`; profile_device API + cache; true; Y | M / no | reload | P1/device | Performance |
| Auto-play next episode | Playback/player | `playback.auto_play_next`; profile_device API + cache; true; Y | M / no | reload | P0 | Do not confuse with `player.autoPlayNextEpisode` cache |
| Show Next Up timing | Playback | `playback.next_up_prompt_seconds`; profile_device API + cache; 30s; Y | M / no | reload | P1 | Validate choices |
| Skip intros | Playback | `playback.intro_skip_mode`; profile_device API + cache; contract default; Y | M / no | reload | P1 | Legacy `skipIntros` is cache/migration only |
| Skip credits | Playback | `playback.auto_skip_credits`; profile_device API + cache; false; Y | M / no | reload | P1 | Low |
| Video skip back | Playback | `player.video_skip_back_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Four-key seek contract; server revision gate |
| Video skip forward | Playback | `player.video_skip_forward_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Same |
| Audiobook skip back | Playback | `player.audiobook_skip_back_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Same |
| Audiobook skip forward | Playback | `player.audiobook_skip_forward_seconds`; profile API + SD cache; contract interval; Y | M / no | reload | P1 | Same |
| Subtitle language | Subtitles | `playback.subtitle_language`; profile API; none; Y | M / no | reload | P0 | Respect profile vs series override |
| Subtitle behavior | Subtitles | `playback.subtitle_mode`; profile API; auto; Y | M / no | reload | P0 | Respect profile vs series override |
| Show forced subtitles | Subtitles | `playback.show_forced_subtitles`; profile API; true; Y | M / no | reload | P1 | Respect profile vs series override |
| Metadata language | Subtitles | `catalog.metadata_language`; profile API; none; Y | M / no | reload | P1 | AI/server capability |
| Subtitle appearance (font, color, opacity, outline, background, position) | Subtitles/player | `playback.subtitle_appearance`; profile or profile_device API + cache; default appearance; Y | M / no | reload | P1, one atomic record | Preset fields are not separate persisted settings; preserve scope |
| Match device caption settings | Subtitles/player | `subtitle.matches_device` / scoped `player.subtitleMatchesSystemAppearance`; UD/device state; false; Y | M / no | reload | P1/device | iOS Accessibility values themselves must not be exported |
| Subtitle appearance only on this device | Subtitles/player | scoped `player.subtitleUsesDeviceAppearanceOverride`; UD + API scope; false; Y | M / no | reload | P1/device | Scope transition must not erase profile choice |
| Video sizing/aspect | In-player settings | `player.video_gravity`; profile_device API + cache; Fit; Y | M / no | reload | P1/device | Active session may need player command |
| Playback speed | In-player settings | `player.playback_speed`; profile_device API + cache; 1.0; Y | M / no | reload | P1 | Validate allowed numeric values |
| Orientation lock | Player | `player.orientation_mode`; profile_device API + cache; Landscape Locked; Y | M / no | reload | P1/device | iPhone geometry |
| Subtitle sync offset | Player | `player.subtitle_sync_ms`; profile/device API + cache; 0ms; Y | M / no | reload | P2 | Live player command needed |
| Preserve browse sort/filters | Library browse | `ios.browsePrefs.<server>.<profile>.<library>[.type-*].preserve`; SD; true; Y | D / no | reload | Decide optional/catalog-bound | Scope and ID mapping; turning off deletes saved state |
| Remembered browse sort/filters | Library browse | same prefix `.state`; SD Codable; none; Y | D / no | reload | Decide optional/catalog-bound | Catalog-dependent filter IDs; not one row per library |
| Pinned/hidden Live TV categories | Categories | `kyro.liveTV.categoryPreferences.build78.provider.<UUID>.pinned/.hidden`; UD Codable; empty; Y | D / no | reload | Decide optional/provider-bound | Category names can collide across providers; preserve order and avoid wrong catalog |
| Favorite Live TV channels | Guide/channel actions | `liveTV.favorites.v1`; UD string IDs; empty; Y | D / no | reload | Decide optional/provider-bound | IDs embed provider UUID; do not import blindly |
| Favorite movies/series/other library items | Item detail → Favorites | server `/api/v2/favorites` database; empty; Y | D / no | reload | Decide optional/profile-bound data | Server-owned collection, not a scalar setting; catalog IDs need matching and merge policy |
| Active Live TV provider/playlist configuration | Live TV Settings | `liveTV.providers.v1`; UD Codable; none; Y | X / no | N/A | Exclude | URLs and credentials may be embedded |
| Selected Sports league/category | Sports Hub | `kyro.sports.selectedLeague` / `.selectedCategory`; UD; NFL/All; Y | X / no | N/A | Exclude as navigation state | Persisted last location, not a durable preference |
| Calendar filter | Calendar | `calendar.filter`; UD; all; Y | D / no | reload | Decide optional personalization | Persisted filter, not exposed in Settings |
| Selected library / browse page | Library tabs | scoped selected-library ID / `ui.library_page_state`; UD/API; first library; Y | X / no | N/A | Exclude navigation state | Library IDs are server-specific |
| Diagnostics destination | Privacy | diagnostics consent model; account/server storage; hosted; Y | X / no | N/A | Exclude | Privacy routing must be chosen by user on destination |
| Crash-report consent | Privacy | diagnostics consent model; account/server storage; Ask; Y | X / no | N/A | Exclude | Never transfer consent silently |
| Watch Party experimental switch | Appearance / optional features | `experimental.watchParty`; UD; off in Release; Y | X / no | N/A | Exclude | Experimental/internal flag |
| EPG SQLite storage / diagnostics overlays | Advanced diagnostics | `kyro.internal.epg.sqliteStorage` and diagnostics keys; UD; off; Y | X / no | N/A | Exclude operational switches | Debug/performance, not portable preference |
| Hidden libraries | Library visibility (no iOS editor found) | `ui.disabled_library_ids`; API + cache; none; iOS read path | C / no | N/A | Verify iOS editor first | Library IDs cannot be assumed stable; current Apple path only reads |
| Library pin/order | Interface/library actions | `ui.library_order` / `ui.sidebar_pins`; API; contract default; Y | D / no | reload | Decide optional/catalog-bound | Catalog IDs and cross-client scope |
| Home hide watched items | Home customization | `home.hide_watched_items`; API; contract default; unverified iOS persistence | C / no | N/A | Verify iOS editor first | Contract key alone does not prove production iOS control |
| Requests watchlist auto-request | Watchlist/Requests | `requests.watchlist_auto_request`; API; contract default; unverified iOS persistence | C / no | N/A | Verify iOS editor first | May be server preference; avoid claiming iOS editor from manifest |
| Search media scope | Search | `search.media_scope`; API; contract default; unverified iOS persistence | C / no | N/A | Verify iOS editor first | Search session filters must not be confused with saved scope |

**Count qualification:** the four `C` rows are *candidates*, not proven iOS-editable preferences. They are not in the 74 or eligible denominator. Their status must be resolved with a focused production-path check before implementation. The category pin/hidden row represents two fields within one provider-scoped customization record, not a count of category names. The server Favorites collection is counted once as a user-managed collection, not once per title; product may choose to treat it as library data outside settings backup.

## Backup implementation findings

* The allowlist is `SettingsBackupLiveRegistry.make`. The exporter iterates only the selected groups, reads the owning store and validates the scalar. It never scans all of `UserDefaults`. Nine groups exist: five portable (navigation, categories, guide, sports, downloads) and four opt-in same-idiom groups (playback, PiP, advanced A/V, navigation layout). All 29 registered IDs have both read and write closures. There is **no export-only registered entry**, and no evidence of a stale key for the registered category or guide settings: category appearance/grouping use the new dedicated keys, with legacy data only as fallback.
* **Twelve entries are misleading as user preferences.** Five Sports supplement flags have a real UD read/write path and default on, but no production control outside Backup & Restore; they are internal feature flags. Seven `nav.*` entries use `KyroGlobalNavigationStore` (`kyro.navigation.global.v1`), while the actual floating Live TV settings editor uses `KyroLiveTVNavigationStore` (`kyro.liveTV.navigation.v1`). The global style/geometry fields are not consumed by the current native shell; the Live TV editor is only offered when unified navigation is off (including iPad). Thus Build 93 backs up the **wrong storage record** for those seven visible legacy controls. Do not repurpose old backup IDs to mean the legacy store; preserve old-file interpretation and add new IDs if approved.
* The `downloads.preferredFormat` getter's `DownloadFormat(rawValue:) ?? .original` can export **original instead of the actual stored value** when a future/unknown format is stored. Treat this as a fidelity defect, not a reason to add an unsupported string to a backup.
* `SettingsBackupCodec` is schema 1, `minReaderVersion` 1. It rejects oversized (>256 KiB), deep, malformed, mis-hashed, unsafe-name/value files; unknown safe groups/IDs survive decode but preview counts and skips them. Validation accepts booleans, integers and short strings only; current safety fragments reject names containing `profile`, `server`, `provider`, `account`, `url`, `database`, etc. This blocks a naïve registry expansion for scoped or structured settings. Do not weaken this filter just to fit new data.
* Preview compares the incoming value with the registered getter and marks unchanged/invalid/unsupported; the screen selects only changes by default. Apply re-reads each selected setting, journals all previous/applied values **before** writing, verifies read-back, rolls back attempted writes on failure, and keeps the journal for one Undo. Undo skips values changed after restore. The multi-store operation is **not crash-atomic**; recovery is offered when Backup & Restore reopens. The journal is a single local atomic file, not a database transaction.
* The restore notification is posted after apply/undo/recovery, including failures. `LiveTVCategoryBrowser` reloads the category values; the guide uses `@AppStorage` for style. Observable navigation/download/player stores should update their own bound views, but new server-backed groups will require explicit async refresh of their owner, player session and open screens. A notification alone does not prove this.
* Server-backed rows are deliberately absent because their setters can enqueue network writes and can affect profiles/other devices. Their UD/SD caches are **not** authoritative persistence. Backing up a cache would risk exporting defaults, a prior profile's value, or a value that the server rejected. Scope/source (inherited vs explicit) is part of the semantic value.
* No evidence in the inspected iOS settings paths of a persisted user theme, notification switch, or general accessibility preference that should be added now. iOS caption/notification permissions live in system settings; contract keys such as `ui.theme`, `ui.high_contrast` and `ui.text_scale` are not proof of an iOS editor. Temporary playback position, current channel, recents, cache, download files, pairing/authentication, tokens, URLs, identities, and provider credentials remain outside settings backup.

## Priority and Build 94 proposal

**P0:** profile-selection behavior without identity; media-card presentation and menu customization; spoiler switches; quality resolution/bitrate; auto-play next; profile subtitle language/behavior. These are prominent settings whose loss is visible after reinstall. **P1:** title art/music, advisory age, remaining playback choices, seek intervals, subtitle style and forced captions, metadata language, device caption mode, player aspect/speed/orientation, and supported download fidelity fix. **P2:** actual legacy Live TV floating controls (not the global shadow record), subtitle sync, catalog-bound browse/category/favorite/library customizations after identity policy, and advanced controls not already covered. This is prioritization, not permission to implement.

1. Keep the schema-1 decoder and all Build 93 IDs/values intact. A Build 94 file with only new scalar IDs in existing groups may stay schema 1/minReader 1; older builds will skip unknown safe IDs. New structured records, scoped values or explicit provenance need a **new schema version** (or a carefully versioned new group) with `minReaderVersion` chosen honestly. Preserve the old decoder; translate old IDs through the existing registry. Never reinterpret an old ID's meaning.
2. Add a typed production-preference registry that declares key, owner, default/inheritance, scope, sensitivity, backup policy and refresh hook. Compare it to the backup registry in a focused test. Do not enumerate all `UserDefaults` or the generated contract enum and assume everything is a user preference.
3. For server-backed preferences, read confirmed authoritative values and explicit scope; never export cache snapshots as settings. Plan per-scope writes, capability checks, validation and conflict behavior. Stage a restore point before network writes; apply only selected differences; verify server read-back; retry idempotently; on failure roll back changed scopes and retain a resumable failure record. If those guarantees cannot be met, keep that group out of Build 94 rather than implying Undo works.
4. Put catalog-bound favorites, hidden categories, browse filters and library/menu IDs in an **off-by-default optional group** only after a user-approved source/destination matching rule. Include a non-secret catalog fingerprint or mapping plan, preview unmatched items, and never overwrite another provider's catalog. The current scalar-only/200-entry/256-KiB envelope and sensitive-name filter cannot carry arbitrary arrays safely; design bounded structured validation and diff semantics first.
5. Refresh each owner after apply/undo: category browser, Live TV service/guide, navigation shell, UI customization, title art/music, spoiler/seek/advisory stores, profile editor, player settings and active playback bridge as applicable. Test a visible screen and a reopened app. Unsupported or renamed keys should appear as skipped, never reset another setting.

### Focused automated checks (no Simulator/full suite)

For every registered production preference, use isolated UD/SD or fake API transport and assert: change the **real owner**, export, change again, preview exact difference, selectively restore, verify authoritative persistence and owner refresh, then Undo. Test untouched keys, inherited-vs-explicit scopes, unavailable server, unsupported contract, cross-profile/catalog mismatch, changed-since-restore, write failure/read-back failure, crash recovery, and Build 93 fixture import. Add a registry completeness test comparing the iOS user-editable inventory to backup policy (`included`, `optional`, `excluded`, `decision`) so a new setting requires an explicit disposition. Run focused Foundation/XCTest in GitHub Actions; do not resume suspended UI/Simulator suites for this audit.

### Decisions required before implementation

1. Should profile/family-synced preferences be backed up at all, and if so should restore write this profile only or also preserve device overrides? This changes data on the server and potentially other devices.
2. Should Live TV and server-library Favorites, hidden/pinned categories, library/menu IDs and per-library sort/filter state be optional? If yes, what constitutes a matching provider/catalog/profile, and should unmatched entries be skipped or manually mapped?
3. Should privacy/consent and experimental/diagnostic controls remain excluded? Recommendation: **yes**. Should the persisted Calendar filter be included as a minor preference or treated as last-view state?
4. Confirm whether legacy floating navigation style should remain presented in backup when unified navigation is active, and how an unavailable download format should be represented without silently substituting `original`.

**Readiness:** ready for review, **not** for Build 94 implementation or packaging. No tests were run because this change is documentation only; the counts and production-path conclusions are static source audit findings, not runtime verification.

## Build 94 implementation addendum

This section records work after the baseline audit; the original 74/60 and Build 93 16/29 figures above remain the historical baseline. Local backup behavior landed in `ef4236b15e0b635a1724e19ce6f0ffcc677639e1`. The Calendar filter and the other 29 local preferences were verified together at `92029107dc5db9f43f1176c41eff21a0b015f94e`. **No Build 94 IPA has been built.**

| Disposition | Preferences / entries |
|---|---|
| Baseline fully covered | 16 real user preferences |
| Baseline partial, now fixed | Download quality: unknown raw values are omitted from new exports rather than replaced by `original`; preview and Undo retain the actual raw previous value |
| Newly covered from baseline missing list | 7 floating Live TV navigation fields from the editor's actual `kyro.liveTV.navigation.v1` store; profile-selection behavior only; device caption-matching toggle only |
| Newly discovered local preferences, now covered | Audiobook visibility (`AppNavPreferences`); floating Live TV destination order and hidden-destination set |
| Calendar filter, now covered | `calendar.filter` through `CalendarFilterPreference`. Missing or unrecognized stored values stay Following, which is what the Calendar screen shows. The selected day and week are not persisted and are not backed up |
| Removed from new exports | 5 internal Sports supplement flags and 7 dormant global navigation-layout fields. Schema-1 Build 93 files still decode; these 12 old entries are reported as skipped and never written to the wrong store |
| Currently fully covered | **30 of 30 approved local preferences (100%)**; **30 of 64** in the audit's broader potential-eligibility denominator (46.9%). The other 34 are blocked by server ownership under the approved policy |
| Intentionally excluded | Credentials, tokens, provider definitions/URLs, privacy consent, diagnostics, caches, session state, device-specific saved handle positions |

The inventory is now **77** unique persisted user preferences/collections. The broad audit denominator grew from 60 to **63** because the baseline audit missed three real local controls: audiobook visibility and the two Live TV destination customizations. It did already include the seven floating navigation fields, profile launch behavior and the caption-matching toggle. The Calendar filter was a decision item outside that 63. Including it makes the broad denominator **64** and the actionable local denominator **30**, all now registered. The other 34 in the broad denominator are not safe local restore targets. In particular, card/menu presentation, quality, language, spoiler settings, title art and theme music are API-backed, and their local `UserDefaults`/`SharedDefaults` representations are caches or pending-write state. Exporting those caches or restoring via them would be misleading; writing the API would violate the approved server-ownership rule. They remain an explicit blocked gap, not a silent default-value export.

### Catalog-bound group blocker

No optional catalog group was added. `LiveTVProvider.id` is a local UUID; [M3U channel IDs](../../iosApp/iosApp/LiveTV/LiveTVModels.swift) hash that UUID with guide ID/name, and [Xtream IDs](../../iosApp/iosApp/LiveTV/LiveTVService.swift) hash it with a numeric stream ID. A matching numeric stream ID, name, provider type or channel count **does not prove** a matching catalog. A provider UUID alone proves only the same local provider record, not unchanged playlist contents. Category customizations use names within that local provider UUID; Favorites use the generated channel IDs. The iOS source exposes hidden **categories**, not a persisted hidden-channel control, so no hidden-channel preference can be added by assumption. Server-library Favorites are a separate profile-scoped server database collection. The currently available non-secret fields do not provide a verified cross-install provider/catalog identity, and the schema-1 scalar envelope cannot represent bounded per-item add/replace/skip previews with robust Undo. Per the approved rule, mismatches are not imported and no catalog-specific data is exported yet. A future optional group requires an authoritative, non-secret stable identity and explicit transactional/Undo design rather than a newly invented fingerprint.

### Compatibility, runtime and verification

New scalar IDs/groups remain in schema 1 with `minReaderVersion = 1`. Build 93 files import through the existing decoder/checksum checks. Existing supported IDs retain their meaning; the old Sports and global-layout IDs are counted as unknown/skipped, never reinterpreted as the new Live TV editor IDs. New local setters update their observable owners; the existing category notification still refreshes its separate local copy. Device-specific groups now export by default but remain same-idiom-only at restore and are not automatically selected for restore, preserving the accepted review safety behavior. The Review screen displays a skipped count even when no supported setting differs.

Focused production-adapter tests cover export → change → preview → selective restore → persistence → Undo for floating navigation, destination order/visibility, profile launch, audiobook visibility, download format, the local caption toggle, and the Calendar filter. A Calendar restore reloads the open screen's filter and leaves the visible week and selected day alone. The production navigation store's persisted CodingKeys are compared with the backup registry so adding a new stored field without a backup disposition fails a test. This is a focused guard, not a claim of automatic discovery of every future Swift setting; new owner stores still need an explicit backup-policy review.

The Calendar filter is now one of the 30 local preferences. It was the open product decision in the previous addendum. The selected day and week remain transient and are excluded. The previous 29 local preferences are unchanged.

**Test result:** [Cloud Simulator run 44462658968](https://github.com/jmargocubs/Kyro/actions/runs/44462658968) on `92029107dc5db9f43f1176c41eff21a0b015f94e` ran `SiloTests/SettingsBackupLiveRegistryTests`: 26 tests, 0 failures. That run includes the Calendar filter plus the previous local preferences, Build 93 legacy skips, and the server-setting exclusions. The earlier 25-test pass on `8fbad5dc` did not include the Calendar filter.

**Readiness:** Build 94 is ready for the separate unsigned IPA workflow as version 1.0.0 build 94, an unverified pre-release. It is not stable until a physical-iPhone acceptance pass. No IPA has been built in this change.

## Unified-backup follow-up (2026-11-19)

The physical-iPhone acceptance pass found a product-blocking gap: a Build 94 backup restored the fourth navigation tab, but **did not restore playback resolution or subtitle language** after those were changed to 480p and Chinese. The earlier readiness statement above is historical; Build 94 is **not** ready as a complete-settings-backup beta.

The current registry still has 30 entries, all local. `SettingsBackupLiveRegistry.standard()` explicitly excludes server-authoritative values. Its synchronous `BackupSetting.read` and `write` closures feed a synchronous exporter, preview planner, applier, and Undo journal. That design cannot safely incorporate the authenticated, asynchronous settings API by reading `PlayerSettings` caches or by enqueueing its setters: preview would not know the authoritative value, and immediate read-back could report success before a server write persisted.

The current source confirms these owners for the three-setting reproduction:

| Preference | Authoritative path | Build 94 backup status |
|---|---|---|
| Fourth tab | `KyroGlobalNavigationStore.preferences.fourthTab`, device-local | Registered as `navigation.fourthTab`; export/restore/Undo supported |
| Streaming resolution | `playback.preferred_quality`, `profile_device` settings API; `PlayerSettings` is a local observable/cache and write coordinator | Not registered; export omits it |
| Subtitle language | `playback.subtitle_language`, `profile` settings API through `ProfileSettingsWriter` | Not registered; export omits it |

The **64** figure is the potential-eligibility denominator from the Build 94 addendum, **not** 64 confirmed-safe portable settings. It consists of 30 registered local preferences plus 34 API-backed candidates. The full inventory remains 77 persisted user preferences/collections, including entries that require an identity decision or are intentionally excluded. The table above and the original inventory identify the production owner; neither constitutes completion of the 34 server-backed adapters.

Implementation must retain one `.kyrosettings` file and one review screen, but move export, preview, apply, and Undo to an asynchronous typed-adapter pipeline. Each API adapter must capture the authenticated server/profile identity, check capabilities and scope, read the canonical value (including inherited-versus-explicit provenance), write through `SiloAPI.putValue` or `deleteValue`, and confirm with a fresh API read. A failed or offline read must mark that setting unavailable, **not** substitute a cache. The journal must retain enough scope and identity to refuse Undo against a different profile or server. Schema 1 must remain decodable; new scoped records need a versioned envelope with integrity and unknown-field handling. Catalog/provider-bound customizations remain excluded until a stable, non-secret identity and a safe merge/Undo policy are established.

No implementation or cloud test result for this follow-up is claimed by this audit. The iPhone reproduction remains failing until a later code change and a new physical-device acceptance pass prove otherwise. No IPA should be built for this follow-up without the separate device-workflow approval.

## Schema-2 implementation status (2026-11-19)

The paragraph immediately above describes the **pre-implementation** state. The implementation in this worktree adds one asynchronous production export/import path, retaining the existing local registry and schema-1 decoder. The iOS UI now uses that path. A schema-2 document carries all selected local groups and two API-backed groups in one payload. The SHA-256 integrity check covers the scope metadata. The metadata is a SHA-256 fingerprint of the server's verified deployment ID and selected profile ID, not their raw values, URLs, credentials or tokens. The authenticated API remains the authority and refuses requests after an owner switch. A destination mismatch skips remote values while allowing safe local values to be reviewed separately.

### Disposition of the 64 potential candidates

| Class | Count | Disposition |
|---|---:|---|
| Device-local, portable | 14 | Registered through the existing production stores; selected by default for export |
| Device-local, same-idiom | 16 | Registered through the existing production stores; export selected by default, restore opt-in and restricted to phone/pad match |
| API-backed, now implemented | 3 | `playback.preferred_quality` at `profile_device`, `playback.audio_language` at `profile_device`, and `playback.subtitle_language` at `profile`; require a verified server and matching profile for restore |
| Other API-backed candidates | 31 | **Not implemented.** Do not call these backed up, restored or proven ineligible merely because their adapters are absent |

Thus **33/64 candidates are confirmed supported in this implementation**, including **17 cross-device-portable choices** (14 local plus three scoped API choices) and 16 same-idiom local choices. The *final* eligible total among the 64 remains undetermined until the other 31 receive their own API/scope/validation review. The 77-row historical inventory above remains the source-by-source inventory; it includes seven decision items and seven intentional exclusions outside the 64 denominator.

The 31 unsupported API candidates are classified by authoritative owner and risk, rather than silently exported from caches:

| Owner / risk | Candidates still unsupported |
|---|---|
| Profile-scope scalar API | Advisory age; both unwatched-episode spoiler controls; four video/audiobook seek intervals; subtitle behavior; forced subtitles; metadata language |
| Profile-device scalar API | Maximum bitrate; buffering quality mode; audio language; HDR; Dolby Vision; seek cache; auto-play next; Next Up timing; intro mode; skip credits; video gravity; playback speed; orientation; subtitle sync offset; theme music and its loop flag |
| Composite, policy- or catalog-sensitive API/scope | Card presentation; primary menu and shortcuts (library IDs); title art's profile-versus-device scope; cellular quality pair; subtitle appearance record; subtitle appearance's device-only scope transition |

This grouping accounts for the remaining 31 candidate rows from the original inventory. Provider-bound pins, hidden categories and Live TV Favorites, catalog-bound Favorites and browse state, server connection definitions, credentials, diagnostics consent, transient navigation, and unsupported contract-only keys are **outside** the 64. They remain excluded for the identity, privacy, or non-preference reasons stated in the inventory. No provider/catalog identity is guessed from names or local UUIDs.

The remote adapter reads batched effective values with the existing authenticated settings API, preserves inherited versus explicit values, validates scalar values, writes with `putValue` or `deleteValue` at the authoritative scope, and confirms a fresh authoritative read. Playback resolution and Audio Language are `profile_device` settings; Subtitle Language is profile-scoped. Audio Language's empty/no-preference state means no device override, so it is encoded as inherited and restored by deleting only that destination profile-device row. Export flushes queued player writes and refuses to proceed while writes remain unsettled. Preview never substitutes `PlayerSettings` or profile caches when offline. Restore journals previous remote values and fingerprints before the first write, reports partial results if a later write or confirmation fails, and offers recovery/Undo against only the same server/profile. Local values still use the existing synchronous store adapters inside the asynchronous orchestration. The Review screen retains explicit confirmation and per-setting selection.

Build 96 adds `streaming.audioLanguage` to schema 2 without changing the schema version or the interpretation of existing IDs. Its source is `playback.audio_language` from the authenticated effective-settings API; writes/clears use the same API at `profile_device`, never the `PlayerSettings.audioLanguage` cache. A profile or server fingerprint mismatch skips this item with the other remote settings. Existing schema-1 files remain local-only and schema-2 files that omit Audio Language remain valid.

**Validation in this worktree:** macOS host checks executed the production codec and remote adapter/model against controlled API fakes: 6 codec checks and 10 unified-flow checks passed (including the Fourth tab + playback resolution + Audio Language + Subtitle Language round trip, Undo, profile mismatch, offline export, timeout, cancellation, selective restore, partial failure and secret exclusion). The iOS `Silo` scheme and test target **compiled** with `xcodebuild build-for-testing` for a generic iOS Simulator destination; no Simulator was booted and no XCTest cases or cloud workflow were run. Compilation is not an executed iOS test pass. No IPA was built.

**Remaining risk:** 32 API-backed candidates have no adapters, open Settings views may require further refresh testing, the server deployment ID is self-asserted (the authenticated connection still authorizes every API call), and the remote journal is recoverable rather than transaction-atomic across network and local stores. The iPhone 480p/Chinese/Fourth-tab scenario is covered by a controlled host test but **has not been rerun on a physical iPhone**. This implementation is not a complete 64-setting backup and is not beta-ready.

## Follow-up inventory finding (2026-11-19)

The Settings → Features → Watch Party switch was an additional persisted user preference not represented in the original 64-candidate denominator. Its owner is `ExperimentalFeatures`, stored under the explicit `experimental.watchParty` UserDefaults key. It is device-local and contains no server or account identity. It is now included as `features.watchParty`; restore routes through `ExperimentalFeature.watchParty.setEnabled`, so disabling also leaves an active party session. Both `false` and `true` are serialized as explicit booleans. Registry coverage increases by one (34 registered settings including the existing three remote definitions). This does **not** complete the remaining API-backed or identity-bound inventory: coverage remains partial and physical-device testing is still required.

## API batch 1: profile-device scalar settings (2026-11-19)

**Outcome:** 14 more API-backed settings now export, preview, restore selectively, confirm with a fresh server read, and Undo through the existing schema-2 `.kyrosettings` file. Coverage of the 64-candidate denominator rises from **33/64 to 47/64**. Registered settings rise from 34 to 48: 31 device-local (the 30 approved local settings plus Watch Party) and 17 API-backed.

The "31 unsupported API candidates" table above counted Audio Language, which Build 96 had already implemented. The true remainder before this batch was **31 without Audio Language**: 10 profile-scope, 15 profile-device and 6 composite/scope-sensitive entries.

### What was added

All 14 are written at `profile_device`, the same scope the owning screens write (`PlayerSettings.playerDeviceSettings`, `playerBufferingQualitySettings`, `ThemeMusicPreferences.keys`; a test pins this). A row from any other scope means this device has no value, which the backup records as `~inherit`; restoring `~inherit` deletes only the destination device row.

| Backup ID | Group | Contract key | Backup value | Notes |
|---|---|---|---|---|
| `streaming.maxBitrate` | Streaming | `playback.max_bitrate_kbps` | int 100…200000, `~null` (explicit "No limit"), `~inherit` | Null and inherited stay distinct |
| `streaming.bufferingQuality` | Streaming | `playback.buffering_quality_mode` | `never`/`ask`/`always` | Revision 23; capability-gated |
| `streaming.hdr` | Streaming | `player.hdr_enabled` | bool | |
| `streaming.dolbyVision` | Streaming | `player.dolby_vision_enabled` | bool | |
| `player.introSkip` | Player | `playback.intro_skip_mode` | `never`/`ask`/`always` | |
| `player.skipCredits` | Player | `playback.auto_skip_credits` | bool | |
| `player.autoPlayNext` | Player | `playback.auto_play_next` | bool | Not the local `player.autoPlayNextEpisode` cache |
| `player.nextUpSeconds` | Player | `playback.next_up_prompt_seconds` | int 0…120 | |
| `player.speedHundredths` | Player | `player.playback_speed` | int 25…300, step 5 (125 = 1.25×) | A backup holds no floats; off-grid server values are refused, not rounded |
| `player.videoSizing` | Player | `player.video_gravity` | `fit`/`fill`/`stretch` | Applies from the next playback |
| `player.orientation` | Player | `player.orientation_mode` | `landscapeLocked`/`rotateFreely` | |
| `player.fastSeeking` | Player | `player.seek_cache_enabled` | bool | ID avoids the word "cache", which the safety filter rejects |
| `interface.themeMusic` | Interface | `ui.theme_music_enabled` | bool | Revision 11; capability-gated |
| `interface.themeMusicLoop` | Interface | `ui.theme_music_loop` | bool | Revision 11; capability-gated |

### Adapter changes

* `RemoteBackupDefinition` is now one typed table (`RemoteBackupValueKind`: bool, contract choice, bounded/nullable integer, speed hundredths, plus the three original kinds). Validation, snapshot, wire conversion and labels come from the kind, so a new scalar needs one table row rather than new adapter code. Choice lists and labels are pinned to the production enums by tests.
* The production transport asks for only the keys the server's contract serves. A batch read fails as a whole on an unknown key, so before this change one newer key would have broken every synced backup on an older server. Keys newer than `SettingKey.minimumServerRevision` (buffering mode, both theme-music flags) are omitted from that server's export. On restore they appear as "This server doesn't support this setting." Any other missing row still aborts export rather than writing an incomplete file.
* Preview distinguishes an unreadable value, an unsupported key and a server value that can't be transferred safely, so every backed-up setting gets a reason.
* After restore or Undo, `PlayerSettings` and `ThemeMusicPreferences` both refresh from the server.
* The model no longer hardcodes the three remote IDs or two groups. `SettingsBackupGroup.isServerSynced` routes `streaming`, `subtitles`, `player` and `interface` to the adapter. The decoder refuses any of them in a schema-1 or unscoped file. Unknown IDs in a synced group are counted as skipped.

**Compatibility:** schema stays 2 with `minReaderVersion` 1. Build 93 schema-1 files and Build 96 schema-2 files (three synced IDs) still import unchanged. A Build 96 reader opening a new file treats `player`/`interface` as unknown groups and the four new streaming IDs as unknown settings, and counts all of them as skipped.

### Validation

* **macOS host checks** (production codec, adapter and model with a controlled fake API; `swiftc -D KYRO_STANDALONE_TESTS`): **42 unified checks passed** (10 existing + 32 new) and **6 codec checks passed**. The new checks are a 23-row table (every setting; both directions for every boolean; explicit-null and inherited bitrate) running export → change → preview → restore at `profile_device` → confirmed read → Undo. They also cover an older server without the gated keys, profile mismatch with zero writes, a write failure mid-restore with recovery, cross-group selective restore, Undo skipping a value changed since restore, out-of-contract values refused in preview and never written, a Build 96 file, an unknown future synced ID, no URL/server/profile identifiers in the document, and schema-1 refusal of the new groups.
* **iOS XCTest:** `SettingsBackupRemoteBatchOneTests` (9 tests, real wire models) and the updated `SettingsBackupUnifiedTests` **compiled** with `xcodebuild build-for-testing` for `generic/platform=iOS`. **They were not executed**; no Simulator was launched and no cloud run was started.
* No IPA was built. tvOS was not modified.

### Remaining API-backed work: 17 of the 64

| Batch | Settings | Why it is separate |
|---|---|---|
| 2 — profile-scope scalars (10) | Show advisory age; blur unwatched episode images; hide unwatched episode descriptions; video skip back/forward; audiobook skip back/forward; subtitle behavior; show forced subtitles; metadata language | Same adapter and table, scope `profile`. Each needs its revision gate (9, 10, 17) and a check that series overrides cannot mask the profile row (subtitle behavior, forced subtitles) |
| 3 — subtitle appearance scope (3) | Subtitle appearance record; "appearance only on this device"; subtitle sync offset | One setting moves between `profile` and `profile_device`, and sync follows it (profile scope from revision 19). The appearance record is an object, which the scalar-only envelope cannot carry without a versioned structured value |
| 4 — paired/scope-choice (2) | Cellular quality pair; title art | Cellular is two keys written atomically (revision 20, iPhone/iPad only). Title art has an apply-to-all choice between profile and device scope |
| 5 — catalog-bound composites (2) | Card presentation; primary menu + shortcuts | Atomic composite objects; menu entries contain library IDs that must resolve against the destination catalog |

Provider/catalog-bound items outside the 64 (Live TV Favorites, pinned/hidden categories, server Favorites, browse state, library order) remain excluded until a stable non-secret identity exists, as described above. Physical-iPhone validation of any API-backed setting is still outstanding.

## API batch 2: profile-scope scalar settings (2026-11-19)

**Outcome:** all 10 profile-scope scalars now export, preview, restore selectively, confirm with a fresh server read and Undo in the same schema-2 `.kyrosettings` file. Coverage of the 64 candidates rises from **47/64 to 57/64**. Registered settings rise from 48 to **58**: 31 device-local and 27 API-backed (14 profile-device from batch 1, the three Build 96 settings, and these 10).

Every setting is written and read at `profile` scope through the same authenticated, owner-pinned `putValue`/`deleteValue`/batched effective-read path as batch 1. None writes a `PlayerSettings`, `ProfilePreferences` or store cache.

| Backup ID | Group | Contract key | Revision | Backup value |
|---|---|---|---|---|
| `interface.advisoryAge` | Interface | `catalog.show_advisory_age` | 10 | bool, `~inherit` |
| `interface.hideEpisodeImages` | Interface | `catalog.hide_unwatched_episode_images` | 17 | bool, `~inherit` |
| `interface.hideEpisodeDescriptions` | Interface | `catalog.hide_unwatched_episode_overviews` | 17 | bool, `~inherit` |
| `player.videoSkipBackSeconds` | Player | `player.video_skip_back_seconds` | 9 | one of 5, 10, 15, 30, 45, 60, 90; `~inherit` |
| `player.videoSkipForwardSeconds` | Player | `player.video_skip_forward_seconds` | 9 | same list |
| `player.audiobookSkipBackSeconds` | Player | `player.audiobook_skip_back_seconds` | 9 | same list |
| `player.audiobookSkipForwardSeconds` | Player | `player.audiobook_skip_forward_seconds` | 9 | same list |
| `subtitles.mode` | Subtitles | `playback.subtitle_mode` | 1 | `auto`/`always`/`off`, `~inherit` |
| `subtitles.showForced` | Subtitles | `playback.show_forced_subtitles` | 1 | bool, `~inherit` |
| `subtitles.metadataLanguage` | Subtitles | `catalog.metadata_language` | 1 | language tag, `~null` (Library default), `~inherit` |

An absent profile row is `~inherit` and restoring it deletes only that profile row; an explicit `false` or JSON null is kept distinct from it. Settings whose key is newer than `SettingKey.minimumServerRevision` (seek intervals, advisory age, spoiler toggles) are omitted from an older server's export, listed as not included, and reported as unsupported on restore; subtitle mode, forced subtitles and metadata language (revision 1) always work. The existing test that equates `requiresCapability` with `isNewerThanMinimumServer` covers all ten.

### Override isolation

The effective API returns whichever row wins. For a profile-scope setting, a winning device, client, library or series row is someone else's scope. The adapter now raises a distinct `overridden` outcome: export leaves the setting out and lists "hidden by a device, library or series override"; preview marks it unsupported with the same reason; restore skips it (not "failed") and writes nothing. The effective batch read carries no series context, so in practice a series override cannot reach the backup, and a device or library override is caught if present. Audio language, subtitle sync and subtitle appearance keep their own scope rules. Per-series subtitle overrides are never read or written. One limit remains: while an override hides a profile value, Kyro cannot show or restore that profile value at all, because no scope-targeted read exists in the transport.

A defect found and fixed during this work: one overridden or unreadable setting used to mark every selected synced setting as failed. It now skips only that setting.

### Other changes

* Export reports each omitted synced setting and its reason; the post-export banner turns to a warning and lists them.
* After a synced restore or Undo, the advisory-age, episode-spoiler and seek-interval stores refresh from the server alongside player settings and theme music.
* Schema stays 2, `minReaderVersion` 1. Schema-1 files and Build 96 / batch 1 schema-2 files import unchanged; schema-1 files still cannot carry synced groups.

### Validation

* **macOS host checks:** **67 unified checks and 6 codec checks passed** (`swiftc -D KYRO_STANDALONE_TESTS`, production codec/adapter/model, controlled fake API). New this batch: 18 table rows (both directions for each of the four booleans, explicit null and inherited metadata language, inherited advisory age and skip interval, every interval and mode) running export → change → preview → restore at `profile` scope → confirmed read → Undo; override isolation for device, series and library overrides; valid and invalid intervals for all four keys (rejecting 0, 1, 7, 20, 89, 91, 120, -10, strings and bools); invalid mode, forced, advisory and language values never written; older server; partial failure with recovery; selective restore; Build 96 and schema-1 compatibility. Profile mismatch with zero writes is covered by the existing check, now for 10 synced settings.
* **iOS XCTest:** the updated `SettingsBackupRemoteBatchOneTests` (override isolation, older server, interval validation, pins to `SeekIntervalContract`, `ProfileSettingKeys`, `SubtitleMode`, `EpisodeSpoilerContract`) and `SettingsBackupUnifiedTests` **compiled** with `xcodebuild build-for-testing` for `generic/platform=iOS`. They were **not executed**. No Simulator, IPA or tvOS change.

### Remaining: 7 of the 64

| Batch | Settings | Blocker |
|---|---|---|
| 3 | Subtitle appearance record; "appearance only on this device"; subtitle sync offset | Structured object value and a scope that moves between `profile` and `profile_device` |
| 4 | Cellular quality pair; title art | Two keys written atomically (iPhone/iPad only); apply-to-all scope choice |
| 5 | Card presentation; primary menu + shortcuts | Composite objects; menu contains library IDs needing destination-catalog matching |

Physical-iPhone validation of any API-backed setting is still outstanding.

## API batch 3: subtitle display (2026-11-19)

**Outcome:** the last three scope-sensitive subtitle settings now export, preview, restore selectively, confirm with fresh server reads and Undo in the same `.kyrosettings` workflow. Coverage of the 64 candidates rises from **57/64 to 60/64**. Registered settings rise from 58 to **61** (31 device-local, 30 API-backed).

| Backup ID | Setting | Backup value |
|---|---|---|
| `subtitles.appearance` | Subtitle appearance | a record of all 10 synced members, or `~inherit` |
| `subtitles.appearanceDeviceOnly` | Subtitle appearance "This device only" | true / false |
| `subtitles.syncOffsetMs` | Subtitle sync offset | integer -10000…10000 ms (0 is explicit), or `~inherit` |

### Storage mappings

* **"This device only" is not a stored value.** The Settings switch means "`playback.subtitle_appearance` has a `profile_device` row for this device" (`PlayerSettings.subtitleUsesDeviceAppearanceOverride`, derived from the winning row's scope). The backup records it as a boolean derived from that scope and restores it by creating or deleting that row. Turning it on copies the appearance on screen, as the Settings switch does; turning it off deletes the device row.
* **Appearance:** `playback.subtitle_appearance`, an object at `profile` or `profile_device`. The record carries `fontSize`, `fontFamily`, `fontColor`, `backgroundColor`, `backgroundStyle`, `backgroundOpacity`, `textOpacity`, `textOutline`, `textOutlineColor`, `position`. Runtime-only device caption values (`fontOpacity`, system scale and edge style, caption window) are not synced by the app and are not in the record. A test compares the record's members, lists and defaults with the production `SubtitleAppearance`.
* **Sync offset:** `player.subtitle_sync_ms`. It follows the appearance scope: profile by default, device while the device keeps its own appearance. A server older than revision 19 can only store it per device, so there it is written at `profile_device`.
* The backup stores a complete canonical record (defaults filled in, hex colors normalized to `#rrggbb`). An absent row is `~inherit`; an explicit all-default row is a full record. The three states (inherited, explicit default, custom) therefore stay distinct. The API cannot show whether a stored object was sparse or complete.

### Restore order, atomicity and rollback

The server has no transaction across rows, so restore is an ordered, journalled sequence: **scope switch → appearance (at the resulting scope) → sync offset**. Each row write is saved in the restore point before it is sent, confirmed by a fresh read, and reversed in the opposite order on Undo or recovery.

* The appearance is written at the scope the switch ends with. If the switch is not selected, it is written at the destination's current scope.
* A profile appearance of "inherited" cannot be applied to a device-only destination without the switch (a device row can't be inherited), so that item is skipped and reported.
* Restoring the offset at profile scope first deletes a leftover device offset, which would otherwise hide it. The row hidden behind a device row is read after the device row is deleted, and recorded, so Undo restores both rows.
* Other rows are never written: a device-only restore leaves the profile row alone, and a profile restore leaves a hidden device row alone unless the switch is restored.
* On a failure the confirmed items are reported as restored, the failed item as failed and the rest as skipped, the restore point stays in recovery state, and Roll Back reverses the confirmed rows. Undo leaves a row that changed after the restore, or that a device row currently hides, alone.
* A library or series override that hides the rows, or an appearance object with members this Kyro doesn't know, is not exported (listed with the reason), previewed as unsupported and never written.
* Server revisions: `textOpacity` needs revision 14. On an older server a saved non-default opacity is refused as unsupported; a default one is stored without the member.

### Schema change

**Schema 3** adds one value type, a flat record of scalars. A file is written as schema 3 with `minReaderVersion` 3 only when it contains a record, which is whenever the Subtitles group is exported; any other file stays schema 2 (or 1), so earlier builds keep reading it. Earlier builds refuse a schema-3 file with the "made by a newer version" message rather than misreading it. The decoder refuses a record in a schema-1 or schema-2 file, a nested record, an empty record, more than 16 members, an unsafe member name and a link-like value; records are covered by the SHA-256 integrity hash. Build 93 to Build 97 files import unchanged. The two existing "future schema" tests now use schemas 4 and 5.

### Validation

* **macOS host checks:** **82 unified checks and 13 codec checks passed**. New: 15 unified checks covering the complete 10-field record round trip, profile-scoped and device-only appearance, switching in both directions with Undo of hidden rows, switch-only restore, explicit default vs inherited vs custom, offsets -10000, -750, 0, 1500 and 10000 (explicit zero distinct from inherited), device-scoped and pre-19 server offsets, leftover device offset removal, out-of-range offsets, older server text opacity, partial failure with recovery, selective restore, Undo skipping a row changed since, identity mismatch with zero writes, unknown members and library overrides, a model-level export/restore/Undo through the real model, and Build 96 / schema-1 / schema-2 compatibility. The 67 earlier checks still pass.
* **iOS XCTest:** `SettingsBackupSubtitleDisplayTests` (9 tests, real wire models and pins to `SubtitleAppearance`, the three `Subtitle*Preset` enums and the revision constants) and the updated `SettingsBackupUnifiedTests` **compiled** with `xcodebuild build-for-testing` for `generic/platform=iOS`. They were **not executed**; no Simulator was launched. No IPA was built; tvOS was not modified.

### Remaining: 4 of the 64

| Batch | Settings | Blocker |
|---|---|---|
| 4 | Cellular quality pair; title art | Two keys written atomically (iPhone/iPad only); apply-to-all scope choice |
| 5 | Card presentation; primary menu + shortcuts | Composite objects; menu contains library IDs needing destination-catalog matching |

The device caption-matching toggle (`player.subtitleMatchesSystemAppearance`) was already counted among the 30 local settings. Physical-iPhone validation of any API-backed setting is still outstanding.

## API batch 4: cellular quality and title art (2026-11-19)

**Outcome:** the unified schema-3 adapter now exports and restores both additional logical settings through the authenticated effective-settings API. The potential-candidate count moves from **60/64 to 62/64**; registered supported IDs move from **61 to 63** (31 device-local, 32 server/profile-backed). The two new composite values remain one selectable row each in the existing Streaming and Interface groups.

| Backup ID | API mapping | Portable representation |
|---|---|---|
| `streaming.cellularQuality` | `playback.cellular_preferred_quality` + `playback.cellular_max_bitrate_kbps`, `profile` or `profile_device` | Schema-3 record of scope, resolution and cap; explicit JSON null cap is `~null` (unlimited), while `scope: default` means no authored row |
| `interface.titleArt` | `ui.title_art`, `profile` or `profile_device` | Schema-3 record of the authoritative source scope and boolean; default/inherited is distinct from explicit true |

The adapter uses `storedValue ?? value` for policy-constrained effective rows, confirms each row with a fresh read, and never reads from the `PlayerSettings` or `TitleArtPreferences` caches. Cellular export validates that the two API rows share the same winning scope, and retains the independent pair members rather than reconstructing them from a named preset. This carries custom contract-valid pairs too. It does not run on tvOS: this target and its export UI are iOS-only; the contract keys themselves are available on iOS and iPadOS.

### Multi-row safety and remaining scope limitation

The settings API exposes effective values and the winning scope, but **does not expose a scope-targeted read for a hidden row**. Batch 4 therefore journals and confirms every actual row write, then reverses writes in order on Undo/recovery. It supports cellular explicit profile/device pairs, explicit unlimited caps, both values and schema-3 default/inherited markers. Profile restore is refused when an active device pair hides an unknown profile pair; a default/inherited restore is accepted as unchanged at a default destination but refused if clearing would expose unread lower-scope rows. This avoids destructive guessing.

Title-art profile writes preserve a hidden device row because profile scope wins. A saved device scope applies where no profile row currently wins. Restoring profile scope over a visible device value is safe (writing profile makes it win; Undo removes that new row and reveals the untouched device value). Restoring device scope over a visible profile value is **shown as unsupported**: turning the profile row off would expose a device row that the API cannot read or journal. A saved `default` state is likewise only a no-op when the destination is already at default. This is a concrete API capability limit, not silent omission; preview gives a reason and no writes occur. Full bidirectional scope switching requires the server to add a read-at-scope operation or an atomic scoped mutation API.

### Validation

* **macOS host checks:** **88 unified checks passed**. Added checks cover all eight shipped cellular picker pairs (including each two-key restore), explicit uncapped null vs inherited default, profile-scoped cellular rows, profile title-art restoration while preserving the device row, safe Undo, refusing unsafe reverse scope shifts, a second-row write failure and recovery, an older revision-19 server, mismatched profile with zero writes, and schema-1/schema-2 compatibility. Existing local/remote/subtitle tests also pass.
* **Generic iOS build-for-testing:** `xcodebuild -project Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS' -configuration Debug -jobs 2 CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded (`TEST BUILD SUCCEEDED`). The Silo app and test target compiled, without running tests or launching Simulator.

### Remaining: 2 of the 64 candidates

| Batch | Settings | Work / dependency |
|---|---|---|
| 5 | Card presentation; primary menu + shortcuts | Composite objects; library IDs in menus/shortcuts need destination-catalog identity mapping, validation and safe merge/Undo |

The two visible settings above are not claimed as unconditionally portable across any server state: profile/device hidden-row transitions listed above remain explicitly unsupported until the API exposes those rows. Physical-iPhone validation is still outstanding.

## API batch 5: card presentation and navigation records (2026-11-19)

**Outcome:** the last two *logical candidates* in the original 64-candidate list are registered. Conditional coverage moves from **62/64 to 64/64 candidates**; the concrete backup registry moves from **63 to 66 setting IDs** (31 local, 35 authoritative API-backed). This is **not** 64 unconditionally portable settings: navigation catalog references and downward scope transitions have explicit skip conditions below. The original 74-preference inventory at the top of this historical audit remains a Build-93 snapshot, not a claim about current support.

| Backup ID | Authoritative key | Scope / value | Conditional support |
|---|---|---|---|
| `interface.cardPresentation` | `ui.card_presentation` | `profile`, `profile_client`, `profile_device`; schema-3 record of `scope`, `posterSize`, `caption` | Read from effective API, write at saved scope, fresh-read verify, Undo. Inherited (`scope: default`) differs from an explicit all-default row. A scope can move upward from a visible lower-precedence row without destroying it; downward moves and clearing to default are shown as unsupported when hidden rows cannot be read. |
| `interface.primaryMenu` | `nav.primary_menu` | `profile_client` or `profile_device`; schema-4 ordered `items` array, plus scope. Contract null and inherited default remain distinct. | Built-in destinations are portable. Same-server library/section/collection references require an exact live catalog match by ID **and** name/type; a missing or ambiguous reference skips the entire menu, never a partial remap. Existing destinations absent from the backup also block replacement, so newer unrelated entries are preserved. Cross-server catalog references are refused: the API exposes only local numeric IDs and names/types, not a stable content identity. Cross-server built-in-only menus are allowed after preview and confirmation. |
| `interface.shortcuts` | `nav.shortcuts` | `profile`; schema-4 ordered `items` array (or inherited default marker). | The server's supported atomic item endpoint is used for additions. Restore is offered only when the current ordered list is a prefix of the saved list; existing entries are retained and missing suffix entries are added in order. A replacement, removal or reorder would require an unsafe whole-document PUT, so it is reported unsupported with zero writes. Catalog references require the same identity checks as primary menu. |

### Authoritative and identity rules

The production adapter reads `GET /api/v2/settings/values/effective` with a captured authenticated owner, never `UICustomizationPreferences`' scoped SharedDefaults cache. It checks capability revision 5 or newer through the existing contract gate, writes `ui.card_presentation` and `nav.primary_menu` with the supported `PUT /api/v2/settings/values/{key}` at their actual scope, and changes shortcuts with `PUT /api/v2/settings/values/nav.shortcuts/item`. It confirms each change with a fresh authoritative read. Interface UI refresh uses the existing `UICustomizationPreferences.refresh(force:)` path; pending/held UI edits block backup operations rather than being overwritten.

The adapter reads `/api/v2/user/libraries`; for a section or collection it also reads the appropriate library-specific authenticated catalog endpoint. A saved numeric ID is **never used without comparing the live object identity**. Collection entries without a library context cannot currently be verified and are omitted with a reason. Library names and types alone are not strong cross-server evidence: a new server's “Movies” library could contain unrelated media. No catalog identity is guessed. A server/profile fingerprint mismatch blocks card and other profile-owned settings; built-in-only navigation records may be intentionally restored to another verified destination after the normal import preview and confirmation. A different profile on the **same** server is always refused.

### Schema 4 and restore behavior

Schema 4 adds ordered arrays and bounded nested item records; a document containing one uses `schemaVersion: 4` and `minReaderVersion: 4`. Flat card/appearance records still use schema 3, scalar-only scoped files schema 2, and Build-93 local files schema 1. The decoder rejects arrays/nested records falsely labeled schema 1–3, malformed values, unsafe member names and suspicious strings. A menu array holds at most 64 entries; structured values have a maximum of 1,024 nodes, bounded nesting, and the existing 256-KiB file limit. The entire payload—including item order, scope metadata and reference evidence—is SHA-256 protected. The file never contains a server URL, raw profile ID, credential or token; scope fingerprints remain one-way hashes.

The existing preview shows the ordered current and saved destinations, selected rows, and unsupported reasons. Import still requires the existing explicit confirmation. Every actual write is journalled *before* it is sent and verified after a fresh read. Undo checks that the current row still equals the applied row and refuses to overwrite a subsequent edit. A failed write leaves a recovery point and reports partial restoration; local settings are not claimed restored when a remote write fails. As in earlier batches, the effective API cannot read hidden scoped rows, so transitions that would overwrite an unread row are not attempted. There is no API operation to reorder or remove shortcuts atomically; those restore cases remain unsupported rather than using a stale cache or unsafe whole-record PUT.

### Validation and release status

macOS production-adapter host checks cover card profile/client/device round trips, inherited versus explicit defaults, safe upward scope transitions and Undo, ordered menu restoration with live library/section verification, preservation of newer unrelated menu destinations, atomic shortcut additions and Undo, built-in cross-server restore, catalog-reference cross-server refusal, missing and ambiguous references, profile mismatch with zero writes, selective restore, invalid records, offline read failure and a partial API failure with journalled recovery. Schema checks cover a 64-entry ordered array, integrity tampering, schema-1/2/3 compatibility, schema-3 rejection of ordered values, oversized arrays and nested secret exclusion. See the contemporaneous build and test results in the Batch-5 completion report; iOS XCTest compilation is not a claim that tests ran on a device.

**Validation:** 19 codec host checks and 101 unified host checks executed successfully against the production codec/adapter/model and controlled transport. `xcodebuild -project Silo.xcodeproj -scheme Silo -destination 'generic/platform=iOS' -configuration Debug -jobs 2 CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded after the final changes. It compiled the iOS app and XCTest target but did not execute device tests. The unrelated pre-existing Swift concurrency warnings remain.

**Physical-iPhone validation is still required.** No Simulator or IPA was launched or built in this coding pass. Batch 5 provides maximum safe conditional coverage with the current server contract; cross-server catalog identity, arbitrary shortcut reorder/removal and hidden-row scope transitions need new authoritative server API support before they can be claimed portable.

## Final iOS-wide inventory reconciliation (2026-11-19)

The 64-candidate denominator was **not** an application-wide setting count. This pass checked iOS Settings and its feature editors, the persisted UserDefaults/SharedDefaults writers, the authenticated settings contract, Live TV provider/category/favorite owners, browse persistence, Sports Hub, and the existing backup registry. The historical 77-row inventory included four things that are not durable iOS settings: server Favorites (content collection), last Sports tab and last library (navigation state), and `ui.library_order`/`ui.sidebar_pins` (contract keys without an independent iOS editor; the actual pin action writes `nav.shortcuts`, already covered). Eight previously missed per-league Sports dashboard choices bring the **strict durable, user-editable inventory to 81**: **73 logical choices covered** (74 selectable backup IDs because primary menu and shortcuts are separate records) and **8 intentionally excluded**. Of the 74 registered IDs, 23 are portable local choices, 16 are same-idiom/device-conditional local choices, and 35 use the authenticated server adapter with identity/capability conditions. “Covered” does not mean every possible destination accepts every value.

| Newly found preference | Authoritative owner | Backup disposition |
|---|---|---|
| NFL, NBA, college football, MLB, NHL, ATP, WTA and soccer dashboard view (8 choices) | `kyro.sports.mode.<league>` in UserDefaults; `KyroSportsHubStore.selectDashboardMode` writes each value | **Added** as `sports.dashboardMode.<league>` in the single file. `live`, `upcoming`, `results` and absent/Automatic are distinct; import validates each enum, compares, selectively restores, verifies and journals Undo. The active Sports Hub reloads after restore/Undo. |

The eight excluded durable controls below are **not silently represented as restored**. Backup review now has a “Settings not included in backups” disclosure; the exact technical limits are here. An unsupported value actually present in a backup continues to receive its per-row preview reason.

| Excluded control | Authoritative owner and exact limit | Same-origin possibility |
|---|---|---|
| Preserve browse sort/filters | `BrowsePrefsStore`, SharedDefaults keyed by local server/profile/library ID and optional media scope. Turning it off deletes saved state; no stable library identity/mapping is stored in this local record. | Could be restored to the *same verified server/profile/library* after a scoped enumeration and identity-pinned adapter are added; not safe from a copied defaults key. |
| Remembered browse sort/filters | Same owner plus catalog-specific facet IDs and sort state. A different catalog may not expose the same facets. | Same verified catalog only, after current facet validation and a live browse refresh. |
| Pinned/hidden Live TV categories | `LiveTVCategoryPreferences` in provider-UUID-scoped UserDefaults. Category names can collide or disappear, and the provider UUID is generated locally when a connection is added. | Possible for the exact existing provider UUID after its current category catalog is loaded and verified; not portable to a newly configured provider by name. |
| Live TV favorite channels | `LiveTVService.favoriteChannelIDs` and `liveTV.favorites.v1`. Channel IDs include the local provider UUID; playlist and Xtream catalogs can change. | Possible only for an existing provider/catalog after each channel is re-identified; never replay raw IDs on another installation. |
| IPTV provider configuration | `LiveTVService` provider list plus Keychain `LiveTVSourceConfiguration`; source URLs, username and password can be credentials. | Reconnect manually. A credential-free export would not recreate the connection or prove provider identity. |
| Diagnostics destination | Diagnostics consent/destination owner, tied to account/server and privacy choice. | Must be chosen on the destination; do not silently route reports elsewhere. |
| Crash-report consent | Diagnostics consent owner; legal/privacy authorization is contextual. | Must be chosen again on the destination. |
| EPG storage and diagnostics switches | `@AppStorage` operational flags, including experimental SQLite guide, overlays and debug logging. These alter diagnostics/performance, not personal media settings. | Deliberately excluded even on the same device. |

**Other inspected paths:** watch-screen Guide layout, category layout/grouping, floating Live TV navigation order/visibility, download options, player/subtitle preferences, profile selection behavior, title art, theme music, primary menu and shortcuts are already registered. No separate user-editable channel reorder/hide control exists in the iOS Live TV UI; playlist order is provider data, and the user-facing category pins/hidden controls are the excluded provider-bound record above. `ui.disabled_library_ids`, `home.hide_watched_items`, `requests.watchlist_auto_request`, `search.media_scope`, and `ui.library_order` are contract/read paths without a verified iOS editor, so registering them would invent a preference. Server Favorites are profile-owned catalog data rather than a scalar setting; moving them needs stable item identity and a merge policy, not raw numeric-ID replay. Last-opened Sports category/day, Live TV browse route, selected provider and library are navigation state, not backup preferences.

**Compatibility and validation:** Sports mode records are schema-1-compatible scalars within the existing `sports` group; old Build-93 `sports.*` internal flags remain unknown and skipped without changing another store. Schema 1–4 decoding and the unified file flow are unchanged. **20 codec and 101 unified macOS host checks executed and passed.** Focused iOS XCTest additions cover all eight modes, Automatic versus explicit, restore, Undo, malformed input and active Sports Hub reload; they **compiled** in a successful generic iOS `build-for-testing`, but were not executed without a simulator or device. Physical-iPhone verification remains outstanding.
