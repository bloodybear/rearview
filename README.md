# Rearview

Rearview is a macOS menu bar app that translates Japanese and Korean text from a selected screen region. It uses Apple Vision for OCR and Apple Translation for on-device translation, then displays the result in a mirror or overlay.

## Features

- Japanese, Korean, and English screen text
- Mirror and overlay display modes
- Automatic or manual refresh
- Optional protection for non-source text (off by default)
- Selectable translated text
- Window tracking
- Control bars compact selected labels to icons before using the overflow menu
- On-device processing
- Automatic daily update checks with optional background installation

## Requirements

- macOS 15 or later
- Apple Silicon Mac
- Screen Recording permission
- Japanese and Korean translation language packs

## Download and launch

1. Download the latest `Rearview.dmg` from the [GitHub Releases](https://github.com/bloodybear/rearview/releases) page.
2. Open the DMG and drag `Rearview.app` to the `Applications` folder.
3. Open Rearview from the `Applications` folder.

Because Rearview is currently distributed without Apple notarization, macOS may block the first launch.

If macOS shows a security warning:

1. Try opening Rearview once.
2. Open **System Settings → Privacy & Security**.
3. Click **Open Anyway**, then confirm **Open**.

### Terminal alternative

Remove the download quarantine attribute with Terminal:

```sh
xattr -dr com.apple.quarantine "/Applications/Rearview.app"
open "/Applications/Rearview.app"
```

## Build

```sh
swift build
swift test
```

## Privacy

Screen captures, OCR results, and translations are processed locally. Rearview does not send screen content to an external translation service. By default, mixed text is translated as one unit to preserve context; the optional non-source text protection mode preserves English, Korean, and numeric text but may reduce translation context.
