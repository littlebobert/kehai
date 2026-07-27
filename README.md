# Kehai

Kehai is a personal macOS 27 menu-bar utility for returning to interrupted work. Press **⌘⌥K** to see current window thumbnails, search windows and Safari tabs, and jump to the real item.

## Requirements

- macOS 27 beta with Apple Intelligence enabled for inferred task labels
- Xcode 27 beta selected with `xcode-select`
- XcodeGen at `/opt/homebrew/bin/xcodegen`
- The configured Developer ID identity for team `XDWKSAH7W3`

## Build and run

```bash
./Scripts/reset-build-run.sh
```

This quits Kehai, resets only Kehai's Screen Recording, Accessibility, and Apple Events decisions, regenerates the project, builds a stable signed app, verifies it, and launches it. For normal iteration without resetting permissions or saved app state:

```bash
./Scripts/build-run.sh
```

The individual development operations are also available separately:

```bash
./Scripts/reset-permissions.sh
./Scripts/build-run.sh
./Scripts/open-built-app.sh
```

`reset-permissions.sh` quits Kehai and resets only its three TCC decisions. `build-run.sh` regenerates, builds, signs, verifies, and launches Kehai without resetting permissions. `open-built-app.sh` opens the existing Debug app from `.build/DerivedData/Build/Products/Debug` without rebuilding it.

On first launch, allow:

1. **Screen & System Audio Recording** for faithful thumbnails.
2. **Accessibility** to raise the exact selected window.
3. **Automation → Safari** to enumerate and activate Safari tabs.

After granting Screen Recording or Accessibility, relaunch Kehai if macOS requests it.

## Behavior and privacy

- Thumbnails are captured when the overview opens and are not persisted.
- Activity metadata is stored locally at `~/Library/Application Support/Kehai/activity.json`.
- Safari tabs are never moved, split, closed, or rearranged.
- Inactive Safari tabs show title/domain metadata, not a falsely live preview.
- On-device Foundation Models only suggest labels; navigation always uses deterministic IDs and your click.

## Known limitations

- DRM, secure, and protected windows can appear blank.
- macOS can prevent a third-party utility from crossing some full-screen/Space boundaries perfectly.
- Window IDs last for the current login session; duplicate titles require geometry matching.
- Safari Automation denial leaves the normal window overview usable.
- Foundation Model availability depends on hardware, language, Apple Intelligence settings, and model readiness. Kehai falls back to app-based groups.
- These APIs target beta SDKs and may change before release.
