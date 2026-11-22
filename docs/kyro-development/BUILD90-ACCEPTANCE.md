# iPhone Build 90 physical-device acceptance

Tested on iPhone 16 Plus with Kyro 1.0.0 (90). This candidate is **not accepted** and must not be tagged stable.

| Area | Result |
| :--- | :--- |
| Settings redesign | Pass, 4/4 checks |
| iPhone-to-Apple-TV pairing, including provider transfer | Pass, 6/6 checks |
| Navigation, Live TV, Sports Hub, playback/PiP, Categories | Pass, 5/5 checks |
| Backup export, settings persistence, Undo where exercised | Pass |
| Backup import | Fail: Files shows the exported `.kyrosettings` file but disables selection |
| Import preview with actual differences | Not verified; blocked by picker |
| Immediate Live TV category layout restoration | Not verified; blocked by picker |

The failure occurs before Kyro receives a file URL, so it is **not** evidence that JSON decoding, schema checks, or SHA-256 validation failed. The exported file is named `Kyro Settings 2026-11-17.kyrosettings` and Files reports its Kind as **Kyro Settings Backup**, confirming that iOS recognizes the custom type. The supplied file is 1,205 bytes of JSON with `format: kyro.settings-backup`, schema version 1, reader version 1, and a 64-character integrity hash. Build 90's embedded Info.plist exports `com.cubbiestream.kyro.settings-backup` for `.kyrosettings`. The source picker accepts only `.json`, `.data`, and `.item`, not the file's exact registered type. This type mismatch is the supported explanation for the disabled selection. `CFBundleDocumentTypes` is not needed to make Files recognize the type, and the filename already has the intended extension. Feather resigning has not been shown to alter type recognition; Files' Kind is evidence against that explanation.

For the next candidate, verify that the exported file is selectable from its original Files location, inspect the preview for real differences, apply only a chosen group, verify immediate Live TV category layout refresh, and use Undo. Retest after Feather installation; Simulator tests alone cannot close this acceptance failure.
