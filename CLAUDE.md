# Localview – working rules

## Releases (owner's standing instruction)

- **Never add an update to an existing release.** Every update that is pushed to the platform branches gets its own release.
- For every update: raise `version:` in `pubspec.yaml` (patch for fixes, minor for features; bump the `+build` number too) and add a `CHANGELOG.md` entry.
- The workflows publish to `v<version>` and refuse to touch an existing release that was built from a different source commit (the `Source-Commit:` trailer), so forgetting the bump fails CI instead of merging.
- Platform-branch commits must carry a `Source-Commit: <sha of claude/... dev commit>` trailer.

## Branch layout

- Development happens on the dev branch (shared codebase, all platforms).
- `main` = Windows, plus `linux`, `macos`, `ios`, `android`, `android-tv`, `android-xr`, `steamos`. Each holds the shared code plus only its platform folder and its own workflow; platform branches are regenerated from the dev branch and committed on top of their existing history (no force pushes).
- The `android-xr` branch additionally gets `tool/android-xr/*` (Jetpack XR bridge, PC VR OpenXR client) copied in.
