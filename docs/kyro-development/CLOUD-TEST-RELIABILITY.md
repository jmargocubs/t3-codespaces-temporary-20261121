# Cloud Simulator testing reliability (2026-11-18)

Evidence-based keep / fix / suspend / remove decisions for Kyro GitHub Actions
testing. Reliability and useful feedback matter more than raw test count.

## Audit sample

Recent `cloud-simulator-tests` history (mixed `kyro/m1-rebrand` dispatch and
`kyro/tvos` push/focus runs): **12 success, 11 failure, 5 cancelled**.

### Confirmed findings

| Category | Evidence | Cause class | XCTest useful? |
| --- | --- | --- | --- |
| Focused iOS unit (`only_testing=SiloTests/…`) | [44396020917](https://github.com/jmargocubs/Kyro/actions/runs/44396020917) 63 tests / 0 failures in ~18m; [44361193878](https://github.com/jmargocubs/Kyro/actions/runs/44361193878) SettingsBackupTextImport 9/0 | Works on unsigned free runner | Yes — catches real logic bugs when scoped |
| Full iOS `SiloTests` suite | [44347860882](https://github.com/jmargocubs/Kyro/actions/runs/44347860882) cancelled ~69m; ~3908 keychain `-34018` lines; mass auth/push/session failures; still running at cancel | Unsigned keychain + unrelated suite noise | Partial — early suites run, but green/red is not actionable for feature work |
| iOS UI (`ios-ui`, KyroSettingsBackupUITests) | [44327511809](https://github.com/jmargocubs/Kyro/actions/runs/44327511809) bad selector; [44373285236](https://github.com/jmargocubs/Kyro/actions/runs/44373285236) / [44340578501](https://github.com/jmargocubs/Kyro/actions/runs/44340578501) 4/4 fail (app launch timeout + missing `settingsBackup.*` controls); [44396026717](https://github.com/jmargocubs/Kyro/actions/runs/44396026717) ~71m then **hosted runner lost communication**, no artifacts | Infra / launch / selector; not proven app regressions | No — does not currently give reliable cloud signal |
| Generic tvOS in m1 workflow | [44358219443](https://github.com/jmargocubs/Kyro/actions/runs/44358219443), [44378276081](https://github.com/jmargocubs/Kyro/actions/runs/44378276081) `Unable to find a device matching … Apple TV` despite `simctl` listings | Runner tvOS runtime / destination config | No tests executed |
| Dedicated tvOS focus workflow (`kyro/tvos`) | [44384191832](https://github.com/jmargocubs/Kyro/actions/runs/44384191832), [44362896204](https://github.com/jmargocubs/Kyro/actions/runs/44362896204) ~19–21m success with create/boot-by-id + explicit `-only-testing` list | Focused + prepared simulator | Yes for focus/catalog regressions on that branch |

### Suspected (not fully proven)

- UI runner disconnect on [44396026717](https://github.com/jmargocubs/Kyro/actions/runs/44396026717) is consistent with memory/CPU starvation on the free `xcode-27` image while launching a Debug UI-test host; logs were not retained, so OOM vs network loss is suspected.
- Some UI selector misses after a partial launch may be navigation/timing flake rather than product bugs; physical Build 92 backup acceptance already covers the user-visible Files/paste paths.

### Coverage already elsewhere

- Backup/restore logic: `SettingsBackupCoreTests`, `SettingsBackupTextImportTests`, `SettingsBackupLiveRegistryTests` (cloud-compatible unit).
- Backup/restore UX on device: physical iPhone acceptance docs (`BUILD92-ACCEPTANCE.md`).
- tvOS focus/large-catalog: dedicated focus workflow on `kyro/tvos`.
- Script/metadata CI: `ci-scripts.yml` (Python/bash/Ruby; no Simulator). Present in tree; runs when that workflow is active on the branch’s default CI surface.

## Decisions

| Workflow / surface | Decision | Notes |
| --- | --- | --- |
| `cloud-simulator-tests` / `ios` + explicit `only_testing` | **Keep** | Default path for feature verification |
| `cloud-simulator-tests` / full iOS suite (empty `only_testing`) | **Disable** | Rejected at validation |
| `cloud-simulator-tests` / `ios-ui` | **Suspend** | Sources kept; `allow_suspended=true` escape hatch only |
| `cloud-simulator-tests` / generic `tvos` | **Suspend** | Prefer `kyro/tvos` focus workflow; escape hatch only |
| `kyro/tvos` focus simulator workflow | **Keep** | Proven create/boot-by-id + focused selectors |
| `cloud-unsigned-ipa` + `publish-approved-ipa` | **Keep** | Unchanged; packaging is separate from tests |
| `player-regression.yml` | **Leave** | Not required for routine feature builds; do not auto-enable |
| `ci-scripts.yml` | **Keep** | Fast, no Simulator |
| Physical iPhone / Apple TV acceptance | **Keep** | Required before stable IPA checkpoints |
| Automatic rerun-on-failure | **Do not add** | Avoids duplicate waste |

## Workflow behavior after this change

`cloud-simulator-tests.yml` on `kyro/m1-rebrand`:

1. Requires `only_testing` for `platform=ios`.
2. Rejects `ios-ui` and generic `tvos` unless `allow_suspended=true` (still requires `only_testing`).
3. Job timeout **45 minutes**; `xcodebuild -jobs 2`.
4. Step summary classifies: **passed / failed / not_executed / infrastructure**.
5. Missing execution never counts as success.

## Required before future IPA packaging

Minimum cloud signal before packaging a feature IPA:

1. Focused unit selector(s) covering the changed area on `platform=ios`
   (example: `SiloTests/SettingsBackupCoreTests`).
2. Classification **passed** with an `Executed N tests` line.

Still required after packaging, before calling a build stable:

3. Physical-device acceptance on iPhone and/or Apple TV for user-visible behavior.

Not required for packaging:

- Cloud `ios-ui` runs (suspended).
- Full unsigned `SiloTests` suite.
- Generic m1 `tvos` destination runs.

## On-demand commands

Focused iOS unit:

```bash
gh workflow run cloud-simulator-tests.yml --repo jmargocubs/Kyro --ref kyro/m1-rebrand \
  -f platform=ios \
  -f ref=kyro/m1-rebrand \
  -f expected_sha=<sha> \
  -f only_testing=SiloTests/SettingsBackupCoreTests \
  -f allow_suspended=false \
  -f use_cache=true
```

Experimental suspended UI (not routine):

```bash
gh workflow run cloud-simulator-tests.yml --repo jmargocubs/Kyro --ref kyro/m1-rebrand \
  -f platform=ios-ui \
  -f ref=kyro/m1-rebrand \
  -f expected_sha=<sha> \
  -f only_testing=KyroIntroUITests/KyroSettingsBackupUITests \
  -f allow_suspended=true \
  -f use_cache=true
```
