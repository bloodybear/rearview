# Rearview

Rearview is a macOS menu bar app that translates Japanese and Korean text from a selected screen region. It uses Apple Vision for OCR and Apple Translation for on-device translation, then displays the result in a mirror or overlay.

## Features

- Japanese, Korean, and English screen text
- Mirror and overlay display modes
- Automatic or manual refresh
- Selectable translated text
- Window tracking
- On-device processing
- Automatic daily update checks with optional background installation

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
