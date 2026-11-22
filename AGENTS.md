# Repository Guidelines

## Project Structure & Module Organization

This repository contains only the Silo Apple clients. SwiftUI app code lives under `iosApp/iosApp/`, tests live in `iosApp/Tests/`, Top Shelf code lives in `iosApp/TopShelf/`, resources live in `iosApp/Resources/`, and generated Xcode structure is controlled by `iosApp/project.yml`. Apple TV playback notes live in `docs/tvos-player/`; release automation lives in `fastlane/`.

## Silo Workspace Context

This repository is part of a broader multi-repo Silo workspace. The sibling
repositories are usually checked out alongside this repository.

- `silo-apple` owns iOS, tvOS, and macOS client code only.
- `silo-server` owns the Go backend, web admin UI, API contracts, auth/session
  behavior, catalog/scanner/playback services, database migrations, Jellyfin
  compatibility, and host-side plugin runtime.
- `silo-android` owns the Android phone and TV clients. When changing shared
  client behavior, compare Android so Apple and Android stay aligned.

When a task touches auth, API models, playback/session state, library browsing,
metadata display, or server-driven behavior, check whether the server and
Android client need coordinated changes. Do not force server concerns into this
repo.

## Build, Test, and Development Commands

- `cd iosApp && xcodegen generate` regenerates `Silo.xcodeproj` from `project.yml`; do this after target or source layout changes.
- Use the `mac-builder` skill's local simulator helper for iOS/tvOS build, boot,
  install, launch, and verification. Reuse the task's established simulator and
  preserve signing and keychain entitlements for authenticated runs.
- Use scheme `SiloTV` with a tvOS simulator destination for tvOS builds.
- Use scheme `SiloMac` with `platform=macOS` for macOS builds.

Follow `mac-builder` host routing for local and remote builds. Simulator boot and
reasonable build recovery are part of an authorized run; ask only for an ambiguous
target or a change that would lose protected state. Unsigned compilation with
`CODE_SIGNING_ALLOWED=NO` is compile-only evidence; do not install that artifact
for an authenticated run. See `docs/mac-builder.md` for setup and background.
Build recovery must follow the Mac Resource Limits in global instructions (no clean builds, DerivedData deletion, or extra simulators without approval).

## Device Testing Workflow

This section overrides the simulator guidance above. The primary test device is an
iPhone 16 Plus running unsigned IPAs installed through Feather.

- Do not boot or launch iOS Simulator for routine functionality or visual checks
  unless the developer explicitly approves it. Do not add debug launch routes whose
  only purpose is to reach a screen in Simulator.
- Verify without Simulator first: static checks and focused unit tests that run
  without a simulator where they cover the change.
- When device testing is needed and the implementation is ready, build one unsigned
  Release IPA for Feather. Do not build or archive it until the developer approves.
  Avoid repeated archives, concurrent builds, and full test runs without new risk.
- Use `-jobs 2` and one Xcode build at a time. Never modify production
  authentication to support testing.

## Coding Style & Naming Conventions

Use Swift 5 and SwiftUI naming conventions. Types use `PascalCase`; functions and properties use `camelCase`. Keep platform-specific code under the existing `iOS`, `tvOS`, or `macOS` folders and update `project.yml` instead of hand-editing generated `.xcodeproj` files. Preserve existing Apple bundle IDs and keychain groups during this migration for TestFlight continuity.

For tvOS focus work, read `docs/tvos-focus.md` before editing navigation,
menus, grids, or custom controls. Prefer a stable native focus graph or a
single composite focus owner; do not mix row-level focusable controls with
manual directional focus mutation.

## Approved tvOS Baseline (Build 104)

Kyro tvOS Build 104 is the accepted, physically tested Apple TV baseline:
- **Repository:** `jmargocubs/Kyro`
- **Branch:** `kyro/tvos-build104-recovery`
- **Source commit:** [`f66d9e929cce41c90b67bbeaffaf057f342438d1`](https://github.com/jmargocubs/Kyro/commit/f66d9e929cce41c90b67bbeaffaf057f342438d1)
- **Release:** [`kyro-tvos-v1.0.104-build104-rc1`](https://github.com/jmargocubs/Kyro/releases/tag/kyro-tvos-v1.0.104-build104-rc1)
- **Status:** Main navigation, Live TV toolbar, Movies, Series, Sports Hub, Search, and Settings are verified functional on Apple TV hardware.
- **Accepted deferred polish:** Movies and Series dropdown focus delays / second-option entry, and intermittent category-to-channel focus handoff are nonblocking and accepted for now.
- **Integration invariants:**
  1. Future tvOS integration must preserve Build 104's working UI, navigation, and focus behavior.
  2. Continue the Kyro-independent architecture roadmap: Kyro-owned identity/profiles, provider-independent startup, Silo as optional provider, and preservation of existing Silo features when connected.
  3. **No redesign or replacement of the existing app UI.**
  4. Do not overwrite newer Labs architecture code with Build 104 source.
  5. Do not automatically bulk-merge the recovery branch; integrate fixes selectively.

## Testing Guidelines

Apple tests use XCTest under `iosApp/Tests/`. Add focused regression tests when
they meaningfully protect changed behavior; use rendered checks for visual changes.
Avoid tests that only mirror wording or implementation. Run relevant checks while
iterating and complete repository-required gates at their stated milestone.
Broaden or repeat testing only for new changes, failures, or unresolved risks.

## Writing

Run a final readability pass on every human-facing issue, pull request,
document, or status update.

- Lead with the outcome.
- Use concrete, plain language and active voice.
- Cut filler, stock framing, repetition, and promotional claims.
- Preserve meaning, evidence, citations, uncertainty, and established
  terminology.
- Never rewrite exact quotations, commands, logs, identifiers, API names, or
  contractual language.
- Match the tone to the audience and use only formatting that improves
  readability.

## Pull requests

Never create a pull request unless the developer explicitly asks for one.

Use a Conventional Commit title in plain language. Start the body with the
problem, explain the solution next, and end with the required AI disclosure,
including the exact model identifier, agent harness, and any other AI tooling.
Include repository-required issue links, validation evidence, risks, and
follow-up work.

- Keep one concern per pull request. Split changes that solve independent
  problems or can be reviewed and shipped separately.
- Every pull request that changes what a user sees must include evidence, as
  [Show visible changes](CONTRIBUTING.md#show-visible-changes) defines. That
  covers UI and UX changes and changes to which items appear or what they show,
  such as search results, home sections, recommendations, sorting, filtering,
  metadata, or artwork. Use before-and-after captures of the same screen with the
  same data, and a short recording when motion, timing, or focus matters.
  Capture each device the change can reach: iPhone, iPhone Duo (folded and
  open), iPad, Mac, and Apple TV, or say why a device is unaffected. Write
  `Evidence: none, no user-visible change` only when that is true.
- Attach evidence on GitHub under the PR body's Evidence heading, or publish it
  with `npx @silo-server/evidence publish <folder> --pr <number>` and put its
  `Evidence:` link there. Only Silo maintainers and the pull request's author can
  open a published page. GitHub has no API for attaching images to a pull
  request, so an agent either publishes with the CLI or gives the developer the
  captures to attach. Check media for private information before it goes on
  GitHub. When publishing exits 4, ask the developer to run
  `npx @silo-server/evidence login`; never approve that login or read the saved
  key. Never commit PR-only assets such as `.github/pr-assets/`.
- When babysitting a pull request, poll checks and review comments created
  after the last push. Verify bot findings against the source, fix real issues,
  and dismiss false positives with a written reason. Remain quiet when nothing
  new has appeared. Stop when the latest commit is green.

## Security & Configuration Tips

Do not commit local signing overrides. Start from `iosApp/Signing/Local.xcconfig.sample`, create `iosApp/Signing/Local.xcconfig`, and regenerate with XcodeGen after signing changes. Keep App Store Connect keys, Match repo URLs, and team identifiers in environment variables only.
