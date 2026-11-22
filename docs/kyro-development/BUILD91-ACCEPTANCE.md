# iPhone Build 91 physical-device acceptance

Candidate for verifying the Backup & Restore Files picker fix after Build 90 failed selection of exported `.kyrosettings` files.

| Field | Value |
| :--- | :--- |
| Version | 1.0.0 (91) |
| Bundle ID | `com.cubbiestream.kyro` |
| Source | `kyro/m1-rebrand` @ `732af722f551a5dd16ad47d91239cac29074eefe` |
| IPA | `Kyro-v1.0.0-Build91-Unsigned.ipa` |
| Size | 29,250,960 bytes |
| SHA-256 | `e0b838d20c7d864b5f257870cb3e38f8cf654231c65fa8c3af303e56a669b429` |
| Pre-release | https://github.com/jmargocubs/Kyro/releases/tag/kyro-ios-v1.0.0-build91-rc1 |
| Cloud build | https://github.com/jmargocubs/Kyro/actions/runs/44254500081 |
| Simulator evidence | Backup core 60/60 and live registry 16/16 XCTest on GitHub Actions (runs 44245505820, 44245521348) |
| Status | **FAILED physical acceptance (2026-11-18).** Backup import does not work. Superseded by the Build 92 candidate. |

## Required physical checks (iPhone 16 Plus / Feather)

1. Install Build 91 as an update (same cert; keep bundle ID, app group, keychain group).
2. Export settings to a `.kyrosettings` file.
3. Open Backup & Restore → Import and confirm the exported file is **selectable** in Files (not greyed out).
4. Confirm import preview shows real settings differences.
5. Apply a selected group only; confirm unselected groups stay unchanged.
6. Confirm Live TV category layout restores immediately after import.
7. Confirm Undo restores the previous values.

Do not mark this build stable until steps 3–7 pass on device.

## Result (2026-11-18, iPhone 16 Plus, screen recording)

**FAIL.** Builds 88, 90 and 91 all failed this check.

What the recording shows:

- Export works. Files saves `Kyro Settings 2026-11-18.kyrosettings` (the Replace Existing Item dialog shows the full name).
- iOS knows the type: Files search offers a **Kyro Settings Backup** kind chip.
- In the import picker both `.kyrosettings` files are drawn at full brightness, like every other file. They are **not** greyed out in Build 91.
- Tapping a file does nothing. A long press opens the Files context menu. The picker never closes, and Kyro shows neither a preview nor an error. The user swipes the picker away.

What the shipped IPA contains (`Payload/Silo.app/Info.plist`, SHA-256 `e0b838d2…`):

- `UTExportedTypeDeclarations`: `com.cubbiestream.kyro.settings-backup`, conforms to `public.json` and `public.data`, extension `kyrosettings`. Matches source.
- No `CFBundleDocumentTypes`, `LSSupportsOpeningDocumentsInPlace` or `UIFileSharingEnabled`. None of these is needed for an in-app picker.
- Importer types at runtime: `[settings-backup, public.json, public.data, public.item]`.

Conclusion: file eligibility and type registration are correct in Build 91. The pick never reaches the SwiftUI `.fileImporter` completion. The exact internal reason is unconfirmed. The importer shared one view with `.fileExporter`, a combination known to misbehave, and `.fileImporter` has device-only failure reports where `UIDocumentPickerViewController` works.

Also seen: a later screenshot shows a Save sheet with the name `.json` and the iOS error "You can't use a name that begins with a dot". Kyro's exporter always names `.kyrosettings` (confirmed in the recording), so this sheet most likely came from another app or a manual rename. Not treated as a Kyro defect.

Not verified: preview with real differences, selective restore, Undo and Live TV category refresh on device. None could be reached.
