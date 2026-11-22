# Kyro Feature Tracking Matrix

**Last Updated:** 2026-11-17  
**Tracking System Version:** 1.2.0

---

## 1. Feature Identification & Status Matrix

| Feature ID | Feature Name | Platform | Implementation Status | Canonical Branch & Commit | Device Test Status | Integration Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `FEAT-CAT-84` | Categories Navigation & Layouts | iOS | Complete | `kyro/m1-rebrand` (`7f9224e5`) | **Accepted** (Physical iPhone, Tag `kyro-v1.0.0-build84-stable`) | Integrated on `kyro/m1-rebrand` and `kyro/tvos` |
| `FEAT-SET-86` | Settings Redesign & Diagnostics Move | iOS | Complete | `kyro/m1-rebrand` (`94d9ad78`) | Unit/Integration tests pass | Integrated on `kyro/m1-rebrand` |
| `FEAT-BAK-88` | Settings Backup & Restore (`.kyrosettings` + 88.2 Fix) | iOS | Complete | `kyro/m1-rebrand` (`557ee779`) | 14 unit test cases pass; import picker pending physical iPhone test | Integrated on `kyro/m1-rebrand` |
| `FEAT-PAIR-CORE` | Live TV Pairing Protocol Core (X25519/ChaChaPoly) | Shared (iOS & tvOS) | Complete | `kyro/m1-rebrand` (`45f2e160`) / `kyro/tvos` (`72c6a81a`) | Verified via unit tests (`LiveTVPairingTests`) | Identical implementations on `kyro/m1-rebrand` and `kyro/tvos` |
| `FEAT-PAIR-IOS` | iPhone Live TV Pairing Sender & UI | iOS | Complete | `kyro/m1-rebrand` (`e4750bd7`) | Routing & client tests pass; pending physical Apple TV pair-test | Integrated on `kyro/m1-rebrand` |
| `FEAT-PAIR-TV` | Apple TV Pairing Receiver & Approval Flow | tvOS | Complete | `kyro/tvos` (`c9371b79`) | Unit tests pass; pending physical Apple TV test | Integrated on `kyro/tvos` |
| `FEAT-TV-NATIVE` | tvOS Native App Foundation & Top Shelf | tvOS | Complete | `kyro/tvos` (`4482a88a`, `8118b2f1`) | Compilation verified | Integrated on `kyro/tvos` |
| `FEAT-TV-LIVETV` | tvOS Native Live TV Experience | tvOS | Complete | `kyro/tvos` (`bd323e54`) | Unit tests pass | Integrated on `kyro/tvos` |
| `FEAT-TV-SPORTS` | tvOS Native Sports Hub & Playback Driver | tvOS | Complete | `kyro/tvos` (`7c5925d6`) | Unit tests pass | Integrated on `kyro/tvos` |
| `FEAT-TV-FOCUS` | tvOS Siri Remote Focus Predictability & Treatment | tvOS | Complete | `kyro/tvos` (`5bc4cd6e`) | Focus unit tests pass (`KyroTVFocusTests`); pending Apple TV test | Fast-forwarded into `kyro/tvos` |
| `FEAT-EPG-SEARCH` | EPG Programme Search & Query Seam | iOS | Complete | `kyro/m1-rebrand` (`595a8397`, `fa961be2`) | Verified in Build 26–31 baselines | Integrated in `kyro/m1-rebrand` baseline |
| `FEAT-PIP-69` | PiP Repair, Sports Polish & Pregame | iOS | Complete | `kyro/m1-rebrand` (`5a245367`) | **Accepted** (Physical iPhone, Tag `kyro-v1.0.0-build69-pip-verified`) | Integrated in `kyro/m1-rebrand` baseline |

---

## 2. Feature Detailed Profiles

### `FEAT-CAT-84`: Categories Navigation & Layouts
- **Platform:** iOS
- **Source Paths:**
  - `iosApp/iosApp/LiveTV/Guide/LiveTVCategoryBrowser.swift`
  - `iosApp/iosApp/LiveTV/LiveTVBrowseModel.swift`
  - `iosApp/iosApp/LiveTV/LiveTVViews.swift`
  - `iosApp/Tests/KyroBuild73CategoriesTests.swift`
- **Verification:** Physically verified and accepted on iPhone 16 Plus running Build 84. Tagged as `kyro-v1.0.0-build84-stable`.

### `FEAT-SET-86`: Settings Redesign & Diagnostics Move
- **Platform:** iOS
- **Source Paths:**
  - `iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift`
  - `iosApp/iosApp/Screens/Settings/LiveTVDiagnosticsSettingsView.swift`
  - `iosApp/iosApp/Screens/Settings/PlaybackSettingsView.swift`
  - `iosApp/Tests/KyroSettingsIntegrationTests.swift`
- **Verification:** Unit and integration tests pass in suite. Physical device acceptance is unverified.

### `FEAT-BAK-88`: Settings Backup & Restore
- **Platform:** iOS (architecture extensible to tvOS)
- **Source Paths:**
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift`
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupLiveRegistry.swift`
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupModel.swift`
  - `iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift`
  - `iosApp/iosApp/Screens/Settings/SettingsBackupView.swift`
  - `iosApp/Tests/SettingsBackupCoreTests.swift`
  - `iosApp/Tests/SettingsBackupLiveRegistryTests.swift`
  - `iosApp/iosApp/Info.plist` (registered `com.cubbiestream.kyro.settings-backup` UTType)
- **Description:** Export and import of device preferences in JSON format (`.kyrosettings` extension). Includes validation, transactional restore with rollback on error, notification broadcasting (`kyroSettingsDidRestore`), and registry integration. Incorporates Build 88.1 and 88.2 file importer picker corrections (`[.json, .data, .item]`).
- **Verification:** Committed in `557ee779`. 14 unit test cases pass. Physical device testing pending.

### `FEAT-PAIR-CORE`: Live TV Pairing Core
- **Platform:** Shared (iOS & tvOS)
- **Source Paths:**
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingCrypto.swift`
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingModels.swift`
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingProviderStore.swift`
  - `iosApp/iosApp/Pairing/LiveTV/LiveTVPairingSession.swift`
  - `iosApp/Tests/LiveTVPairingTests.swift`
- **Verification:** Covered by tests in `LiveTVPairingTests.swift`. Integrated on `kyro/m1-rebrand` (`45f2e160`) and `kyro/tvos` (`72c6a81a`).

### `FEAT-PAIR-IOS`: iPhone Companion Pairing Sender
- **Platform:** iOS
- **Source Paths:**
  - `iosApp/iosApp/Pairing/LiveTV/iOS/KyroSendToAppleTVView.swift`
  - `iosApp/iosApp/Pairing/LiveTV/iOS/LiveTVPairingBrowser.swift`
  - `iosApp/iosApp/Pairing/LiveTV/iOS/LiveTVPairingClient.swift`
  - `iosApp/Tests/KyroSendToAppleTVRoutingTests.swift`
  - `iosApp/iosApp/Info.plist` (`_kyrolive._tcp` Bonjour registration)
- **Verification:** Routing and unit tests pass. Integrated onto `kyro/m1-rebrand` (`e4750bd7`). Ready for Build 90 candidate packaging.

### `FEAT-PAIR-TV`: tvOS Companion Pairing Receiver
- **Platform:** tvOS
- **Source Paths:**
  - `iosApp/iosApp/Pairing/LiveTV/TVLiveTVPairingReceiver.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVPairingView.swift`
  - `docs/livetv-phone-pairing.md`
- **Verification:** Unit tests pass. Integrated on `kyro/tvos`. Ready for Build 85 candidate packaging.

### `FEAT-TV-FOCUS`: tvOS Siri Remote Focus & Grid Layout
- **Platform:** tvOS
- **Source Paths:**
  - `iosApp/iosApp/tvOS/Components/TVKyroFocus.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVGuideFocus.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVProviderFocus.swift`
  - `iosApp/iosApp/tvOS/LiveTV/TVLiveTVView.swift`
  - `iosApp/Tests/KyroTVFocusTests.swift`
- **Verification:** Unit tests pass (`KyroTVFocusTests.swift`). Integrated on `kyro/tvos` (`5bc4cd6e`). Ready for Build 85 candidate packaging.
