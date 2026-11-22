# Kyro Labs

Kyro Labs is the experimental edition of Kyro. It lives on the `kyro/labs` branch, installs beside
stable Kyro, and is where upstream Silo integration and the Jellyfin, Emby and Plex providers are
developed. Stable Kyro stays on `kyro/m1-rebrand` and is never rebuilt from this branch.

## Stable iOS baseline (Build 110 - do not move)

| | |
| --- | --- |
| Version | Kyro 1.0.110 (Build 110), `com.cubbiestream.kyro` |
| Source commit | `cc9e29e106e9e0b5b6c109c85733ace06fec7f9b` |
| Git refs | `stable/kyro-ios-build110` (annotated), `kyro-ios-v1.0.110-build110-rc1` (release tag) |
| IPA | `Kyro-v1.0.110-Build110-100K-Validation-Unsigned.ipa`, 30,099,276 bytes |
| SHA-256 | `f8b7443384207f1c0601fa7f830b8803f0c1a12e49a98359ede9a0239ccae59a` |

Build 111 (`840a9406`) is a different, later commit. Labs starts from it.

## Approved tvOS baseline (Build 104)

Kyro tvOS Build 104 is the approved, physically tested, usable Apple TV baseline for Kyro Labs and tvOS development.

| | |
| --- | --- |
| Platform | Apple TV / tvOS (`SiloTV`) |
| Version | Kyro 1.0.104 (Build 104) |
| Repository | `jmargocubs/Kyro` |
| Source commit | [`f66d9e929cce41c90b67bbeaffaf057f342438d1`](https://github.com/jmargocubs/Kyro/commit/f66d9e929cce41c90b67bbeaffaf057f342438d1) |
| Branch | `kyro/tvos-build104-recovery` |
| Release | [`kyro-tvos-v1.0.104-build104-rc1`](https://github.com/jmargocubs/Kyro/releases/tag/kyro-tvos-v1.0.104-build104-rc1) |
| Status | **Accepted baseline** (Physically tested and verified on Apple TV hardware) |

### Physical Apple TV Feedback
- Main navigation is usable and stable across the 10-foot UI.
- All major sections and controls are reachable.
- Live TV toolbar navigation works.
- Movies and Series navigation works.
- Sports Hub, Search, and Settings are accessible.
- Overall experience is nearly perfect.

### Known Remaining Issues (Deferred, Nonblocking Polish)
1. Movies and Series dropdowns occasionally require repeated Down presses or a delay before focus enters.
2. Movies dropdown sometimes enters on the second option instead of the first.
3. An intermittent Live TV category-to-first-channel focus handoff issue was previously observed.

These issues are accepted for now as deferred, nonblocking polish. Do not prioritize fixing them ahead of independent architecture completion.

### tvOS Integration & Architectural Invariants
1. **Preserve UI, Navigation & Focus Behavior**: Future tvOS integration plans must preserve Build 104's working UI, navigation hierarchy, and Siri Remote focus behavior.
2. **Continue Kyro-Independent Architecture Roadmap**:
   - Kyro-owned identity and profiles
   - Provider-independent startup
   - Silo as an optional provider
   - Preservation of existing Silo-specific features when connected
   - **No redesign or replacement of the existing app UI**
3. **Do Not Overwrite Newer Labs Architecture Code**: Never overwrite newer Labs architecture code (KyroMediaCore foundation, independent auth/identity runtime, local profiles) with Build 104 source.
4. **Selective Fix Integration Only**: Do not automatically or bulk-merge the recovery branch (`kyro/tvos-build104-recovery`). Integrate relevant fixes selectively and deliberately when appropriate.

## Identity

`Shared/KyroAppIdentity.swift` is the single source of every name below. The build chooses the
variant with the `KyroAppVariant` Info.plist key, set from `Signing/KyroVariant.xcconfig`. A missing
or unknown value means stable, so Top Shelf, tvOS, macOS and unit-test hosts keep Build 110's names.

| Surface | Stable Kyro | Kyro Labs |
| --- | --- | --- |
| Display name | Kyro | Kyro Labs |
| Bundle ID | `com.cubbiestream.kyro` | `com.cubbiestream.kyro.labs` |
| Extensions | `…kyro.NotificationService`, `…kyro.DownloadsActivity` | `…kyro.labs.NotificationService`, `…kyro.labs.DownloadsActivity` |
| App Group / defaults suite | `group.com.cubbiestream.kyro` | `group.com.cubbiestream.kyrolabs` |
| Keychain access group | `<team>.com.cubbiestream.kyro.shared` | `<team>.com.cubbiestream.kyrolabs.shared` |
| Keychain service / account prefix | `com.cubbiestream.kyro` / `com.cubbiestream.kyro.` | `com.cubbiestream.kyrolabs` / `com.cubbiestream.kyrolabs.` |
| IPTV provider secrets | service `….kyro.livetv` | service `….kyrolabs.livetv` |
| EPG fingerprint key | `….kyro.livetv.epg-source-key` | `….kyrolabs.livetv.epg-source-key` |
| Deep-link scheme | `kyro://` (and `silo://` alias) | `kyrolabs://` only |
| Legacy keychain rename | on (`com.continuum.*`) | **off** |
| Push entitlement | `aps-environment` | none |
| Icon | `KyroAppIcon` | `KyroLabsAppIcon` (same art, amber LABS band) |

Names Labs uses do not begin with stable's, so a prefix or suffix scan in one app cannot match the
other's items.

## Local data audit

| Store | Isolated by |
| --- | --- |
| `UserDefaults.standard`, Application Support, Caches, SQLite catalogs (Live TV, EPG, VOD, unified index), poster cache, downloads, settings-backup working files | The app sandbox. Different bundle ID, different container. No code change needed. |
| App Group container and its defaults suite (`SharedStorage.suite`, push display metadata, episode-spoiler cache) | Distinct group name (`KyroAppIdentity.appGroup`) |
| Keychain: Silo tokens, profile tokens, account index, device identity, IPTV provider secrets, EPG key, Seekr key | Distinct service, account prefix and access group |
| Keychain legacy migration (`SecItemUpdate` rename from `com.continuum.*`) | Disabled for Labs (`legacyKeychainService == nil`), so Labs never moves or deletes an item it did not create |
| Background task IDs, download session ID, dispatch-queue labels, logger subsystem | Scoped per app by the OS or by process; no cross-app effect |
| Settings backups (`.kyrosettings` files) | Plain user-moved files. The format is intentionally shared so a stable backup can seed Labs by choice. Labs never reads stable's files on its own. |

Unsigned sideloaded builds are re-signed by the installer, which usually replaces entitlements. The
distinct **names** above are what keep Labs separate in that case, with the entitlement files as a
second layer for properly signed builds.

## Server-side behavior

Both apps may use the same Silo server. Labs signs in on its own and gets its own session and device
record, which is normal authentication.

- **Push:** the Silo server only accepts `com.cubbiestream.kyro` as an APNs topic.
  `ApplePushRegistrationWire.contractViolation` refuses any other topic before a journal entry or
  request is created, so Labs sends nothing to the push registration endpoint
  (`KyroLabsPushContractTests`).
- **External sign-in:** the callback scheme `com.cubbiestream.kyro` is a server contract handled by
  `ASWebAuthenticationSession` and is not registered with the OS, so it stays unchanged.
- Restoring a settings backup writes server-side profile settings. That is user-initiated and the
  same as in stable. Do not restore backups into Labs against the production server without meaning to.

## Release and catalog separation

| | Stable | Labs |
| --- | --- | --- |
| Catalog app id (`feather-apps/scripts/apps.py`) | `kyro` | `kyro-labs` |
| Listing name | `Kyro — Build N` | `Kyro Labs — Build N` |
| Release tag | `kyro-ios-v{version}-build{build}-rc1` | `kyro-labs-ios-v{version}-build{build}-rc1` |
| IPA name (`cloud-unsigned-ipa.yml`) | `Kyro-{version}-{build}-ios-unsigned-arm64.ipa` | `Kyro-Labs-{version}-{build}-ios-unsigned-arm64.ipa` |
| Actions artifact | `Kyro-ios-unsigned-ipa-…` | `Kyro-Labs-ios-unsigned-ipa-…` |
| Versions and builds | tracked per bundle ID | independent |

On this branch the unsigned-IPA workflow expects bundle ID `com.cubbiestream.kyro.labs`, a
`KyroAppVariant` of `labs`, Labs-prefixed extensions and no stable keychain group, and fails otherwise.

## Edits to upstream-owned files

Kept small so a later upstream merge stays cheap. Each replaces a literal with a read of
`KyroAppIdentity.current`.

- `Shared/SharedStorage.swift`: app group, keychain service, account prefix, legacy names, canonical access group
- `Shared/SiloURLScheme.swift`: scheme and accepted aliases
- `Components/AppBrand.swift`: iOS display name
- `LiveTV/LiveTVService.swift`, `LiveTV/EPG/EPGSourceIdentity.swift`: keychain services
- `iosApp/Info.plist`, `NotificationService/Info.plist`: display name, icon, URL name/scheme, keychain group, `KyroAppVariant`
- `project.yml`: icon name, identity file in the Notification Service sources
- `Signing/Silo.xcconfig`, `Signing/SiloNotificationService.xcconfig`, `Signing/SiloDownloadsActivity.xcconfig`: include `KyroVariant.xcconfig`
- Tests: `ProfileLaunchPolicyTests`, `SiriIntentTests`, `TVSignInTests`, `WatchPartyAPITests` follow the build's identity; `SiloRenameMigrationTests` skip under Labs

## Verifying isolation

- `Tests/KyroLabsIdentityTests.swift` is portable (Foundation and XCTest). It checks stable's names against Build 110, disjointness, configuration files, and that no other source hard-codes a stable storage name.
- `Tests/KyroLabsPushContractTests.swift` needs the app host.
- `feather-apps/tests/test_kyro_labs_catalog.py` checks catalog separation on a copy of the feed.
