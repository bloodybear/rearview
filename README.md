# Rearview

Rearview is a macOS menu bar app that translates Japanese and Korean text from a selected screen region. It uses Apple Vision for OCR and Apple Translation for on-device translation, then displays the result in a mirror or overlay.

## Features

- Japanese, Korean, and English screen text
- Mirror and overlay display modes
- Automatic or manual refresh
- Selectable translated text
- Window tracking
- On-device processing
- Automatic update checks in release builds
- Optional background update download and installation on the next app quit

## Updates

Release builds check for updates automatically once a day. The setting is available under
`Settings > General > Updates` and is enabled by default. Background download and installation
is disabled by default and can be enabled separately.

When an update is found, Rearview shows a macOS notification and marks the update in the menu bar.
Clicking the notification or menu item opens Sparkle's standard update window. Rearview never
force-quits the app for an automatic update; an automatically downloaded update is installed the
next time the app quits normally. Manual installation may restart the app through Sparkle's standard
flow.

Notification permission is requested when the first update is found. If notifications are disabled,
the menu bar status remains available. Update checks use the current network connection without a
separate limited-network policy.

## Requirements

- macOS 15 or later
- Apple Silicon Mac
- Screen Recording permission
- Japanese and Korean translation language packs

## Build

```sh
swift build
swift test
```

## Privacy

Screen captures, OCR results, and translations are processed locally. Rearview does not send screen content to an external translation service.
