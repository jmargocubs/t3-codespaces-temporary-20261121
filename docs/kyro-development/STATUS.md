# Kyro Development & Platform Status

**Last Updated:** 2026-11-18  
**Repository:** `<repo>`  
**Tracking System Version:** 1.2.0

---

## 1. Executive Summary

Kyro iOS and tvOS development branches have completed their planned integrations and stand ready for independent candidate packaging:

- **iOS Mainline (`kyro/m1-rebrand`):** HEAD at [`732af722`](<repo>) (plus docs/CI follow-ups). Integrates **Settings Redesign**, **Backup & Restore importer correction** (accepts `com.cubbiestream.kyro.settings-backup` + system fallbacks), and **iPhone Live TV Pairing Sender**. **iPhone Build 91** is packaged and in NullSign; physical backup-import acceptance is pending after Build 90 picker failure.
- **tvOS Canonical Branch (`kyro/tvos`):** HEAD at [`5bc4cd6e`](<worktrees>/kyro-tvos). Verified and **fast-forwarded** to include **Phase 3A Siri Remote focus visibility & grid navigation**. Configured for **Apple TV Build 85** (catalog may show later tvOS candidates separately).
- **Integration State:** All intended features are integrated without duplication or conflicts. Source code is verified and prepared for candidate compilation.

---

## 2. Worktree & Branch Inventory

| Worktree Path | Active Branch | HEAD Commit | Commit Subject | Tree Status | Status / Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `<repo>` | `kyro/m1-rebrand` | `732af722` (+ CI rename commit `3047a753`) | `merge: preserve cloud publishing updates and backup import fix` | Docs dirty locally | Canonical iOS branch; Build 91 packaged |
| `<worktrees>/kyro-tvos` | `kyro/tvos` | `5bc4cd6e` | `fix(tvos): make Siri Remote focus predictable and visible` | Clean | Canonical tvOS branch fast-forwarded to Phase 3A; ready for Build 85 packaging |
| `<worktrees>/kyro-tvos-3a` | `kyro/tvos-phase3a` | `5bc4cd6e` | `fix(tvos): make Siri Remote focus predictable and visible` | Clean | Reference branch (now aligned with `kyro/tvos`) |
| `<worktrees>/kyro-ios-b86` | `kyro/ios-pairing-b86` | `4bf10084` | `fix(ios): open the Apple TV pairing screen from any state` | Clean | Historical source branch for pairing commits; fully integrated into `kyro/m1-rebrand` |
| `<worktrees>/kyro-ios-integration` | `kyro/ios-pairing-integration` | `87685dc8` | `fix(ios): make phone pairing survive first run and report failures` | Clean | Historical integration attempt |
| `<worktrees>/kyro-ios-pairing` | `kyro/ios-tv-pairing` | `5dbee415` | `feat(ios): send a Live TV provider to Apple TV` | Clean | Historical sender branch |
| `<worktrees>/t3-0357580d` | `t3/epg-program-search-index` | `31e1ed26` | `chore(kyro): make unified navigation default and stabilize test configuration` | Clean | Historical search index branch |

---

## 3. Platform Status & Release Candidates

### iOS Platform Status (Build 91 Candidate)
- **Candidate HEAD:** [`732af722`](<repo>)
- **Included Features:**
  - `FEAT-CAT-84`: Verified Categories navigation, layouts, grouping, search, pinning, and scroll restoration.
  - `FEAT-SET-86`: Settings overview redesign and Live TV diagnostics repositioning.
  - `FEAT-BAK-88`: Settings Backup & Restore; importer now names `com.cubbiestream.kyro.settings-backup` and keeps system fallbacks (Build 90 device fail → Build 91 candidate).
  - `FEAT-PAIR-CORE`: Cryptographic Live TV pairing protocol core.
  - `FEAT-PAIR-IOS`: iPhone companion pairing sender UI (`KyroSendToAppleTVView`), Bonjour browser, and deep link routing.
- **Physical Device Gate:** Build 91 failed backup import on device (2026-11-18). Build 92 candidate at `f8c23a96`, not packaged. See [BUILD92-ACCEPTANCE.md](BUILD92-ACCEPTANCE.md).

### tvOS Platform Status (Build 85 Candidate)
- **Candidate HEAD:** [`5bc4cd6e`](<worktrees>/kyro-tvos)
- **Included Features:**
  - `FEAT-TV-NATIVE`: Native tvOS foundation and Top Shelf bundle ID alignment.
  - `FEAT-TV-LIVETV`: Native full-screen Live TV experience.
  - `FEAT-TV-SPORTS`: Native Sports Hub and playback driver.
  - `FEAT-PAIR-CORE`: Cryptographic Live TV pairing protocol core (identical to iOS).
  - `FEAT-PAIR-TV`: Apple TV phone pairing receiver and approval flow.
  - `FEAT-TV-FOCUS`: Phase 3A Siri Remote focus visibility, cyan ring, layout-placed grid cells, and provider back navigation.
- **Physical Device Gate:** Pending physical installation and verification on Apple TV 4K.

---

## 4. Next Actions

1. **Build 91 FAILED** backup import on iPhone 16 Plus: the file was selectable, but tapping it never reached Kyro. Build 92 candidate (`f8c23a96`): UIKit Files picker plus Paste Backup Text fallback. Needs a push, GitHub simulator UI tests, a cloud Build 92 IPA, then device acceptance. See [BUILD91-ACCEPTANCE.md](BUILD91-ACCEPTANCE.md) and [BUILD92-ACCEPTANCE.md](BUILD92-ACCEPTANCE.md).
2. Grant `secrets.KYRO` Contents **Read and write** on `jmargocubs/Kyro` (or split release creation onto `GITHUB_TOKEN` with `contents: write`) so automatic pre-release publishing stops failing with HTTP 403.
3. Execute physical device verification on `Living Room Apple TV 4K` for the current tvOS candidate.
4. Mint independent platform tags only after physical acceptance: `kyro-ios-v1.0.0-build91-stable` and the matching tvOS stable tag.
