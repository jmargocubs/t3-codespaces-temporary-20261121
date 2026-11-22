# iPhone Build 92 physical-device acceptance (candidate)

Replaces the SwiftUI `.fileImporter` that failed on Builds 88–91 and adds an import path that does not depend on the Files picker.

| Field | Value |
| :--- | :--- |
| Source | `kyro/m1-rebrand` @ `f8c23a96` (code) |
| IPA | Not packaged yet |
| Simulator evidence | Pending: the GitHub Actions `cloud-simulator-tests` runs need the commit pushed |
| Status | **Candidate. Not packaged, not accepted.** |

## What changed

- **Import from Files…** presents `UIDocumentPickerViewController(forOpeningContentTypes:asCopy: true)` straight from the top view controller. SwiftUI `.fileImporter` is gone. iOS hands Kyro a private copy, which is deleted after reading.
- **Paste Backup Text…** is a new screen with a Paste button and an editable text field. The text goes through the same decoder, 256 KB limit, SHA-256 check, preview, selective restore, Undo and restore notification as a file.
- **Copy Settings as Text** is a new export option that puts the same backup on the clipboard.
- Backup contents are never logged or sent anywhere. The picker logs only picked/cancelled, a count and the file extension (`com.cubbiestream.kyro` / `settings.backup`).

## Required physical checks (iPhone 16 Plus / Feather)

1. Install Build 92 as an update (same cert; keep bundle ID, app group and keychain group).
2. Backup & Restore → **Export Settings…** → save to On My iPhone.
3. **Import from Files…** → tap the `.kyrosettings` file. Expected: the picker closes and the preview appears.
4. If step 3 fails, record it, then: **Copy Settings as Text** → change a setting (for example Settings → Navigation fourth tab) → **Paste Backup Text…** → Paste → Review.
5. Confirm the preview shows the real differences (for example `Fourth tab: For You → Favorites`).
6. Turn off one group, apply, and confirm the turned-off group stays unchanged.
7. Restore a backup whose Live TV category layout differs; confirm Live TV categories change immediately.
8. **Undo Last Restore** and confirm the earlier values come back.
9. Paste text that isn't a backup and confirm Kyro refuses it on the paste screen with nothing applied.

Accept only when step 3 **or** steps 4–8 pass on the device. Record which import path worked.
