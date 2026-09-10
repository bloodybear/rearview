# Rearview User Guide

Rearview is a menu bar app for recognizing and translating text in a selected area of the macOS screen. It can translate Japanese to Korean and Korean to Japanese. Text recognition and translation are processed entirely on your Mac, and screen content is not sent to external servers.

## Table of Contents

- [1. Before You Use Rearview](#1-before-you-use-rearview)
- [2. Installation and First Launch](#2-installation-and-first-launch)
- [3. First Translation](#3-first-translation)
- [4. Using Mirror and Overlay](#4-using-mirror-and-overlay)
- [5. Translation Refresh and Capture Target](#5-translation-refresh-and-capture-target)
- [6. Using Translation Results](#6-using-translation-results)
- [7. Settings](#7-settings)
- [8. Default Shortcuts](#8-default-shortcuts)
- [9. Troubleshooting](#9-troubleshooting)

## 1. Before You Use Rearview

### Supported Environment

- macOS 15 or later
- Apple Silicon Mac

### Recognition Targets

Rearview aims to recognize text rendered on screen by apps or the system accurately and quickly. Handwriting and images captured with a camera may also be recognized by OCR, but they are not optimization targets, so recognition accuracy is not guaranteed.

Both Japanese-to-Korean and Korean-to-Japanese translation are supported. The default setting is Japanese-to-Korean, and you can choose the translation direction in `Settings → General → Language & Translation`.

## 2. Installation and First Launch

### Install the App

1. Download the latest `Rearview.dmg` from [GitHub Releases](https://github.com/bloodybear/rearview/releases).
2. Open the DMG and drag `Rearview.app` to the `Applications` folder.
3. Launch Rearview from the `Applications` folder.

Rearview requires a macOS security check when it is launched for the first time.

### When First Launch Is Blocked

1. Launch Rearview once.
2. Open **System Settings → Privacy & Security**.
3. Select **Open Anyway** and then open the app.

Instead of using System Settings, you can also run the following commands in Terminal in order.

```sh
xattr -dr com.apple.quarantine "/Applications/Rearview.app"
open "/Applications/Rearview.app"
```

### Allow Screen Recording Permission

1. Launch Rearview.
2. Open System Settings from the permission notice.
3. Allow Rearview under **Privacy & Security → Screen & System Audio Recording**.
4. Quit and relaunch Rearview after changing the permission.

### Prepare Translation Language Packs

When you run a translation for the first time, you may see a notice that the Japanese and Korean translation language packs are required. Follow the instructions to install the language packs, then run the translation again.

## 3. First Translation

1. Choose **Select Area…** from the Rearview icon in the menu bar, or press `⌘⇧1`.
2. Drag over the area containing the text to translate.
3. Wait for OCR and translation to finish.
4. Check the translation result in the mirror window.

**Tip**

- To capture only a specific app, specify the target in **Choose Capture App** (`⌘1`) on the toolbar.

## 4. Using Mirror and Overlay

### Choose Display Mode

Use **Switch Mirror/Overlay Mode** (`⌘2`) on the toolbar to switch the display mode.

| Mode | Description |
| --- | --- |
| Mirror | Displays the translation result in a separate window. |
| Overlay | Displays the translation result over the selected area of the screen. |

### Adjust the Mirror Window

- **Always on Top** (`⌘6`): Keeps the mirror window above other windows.
- **Follow Selection Size** (`⌘8`): Resizes the mirror window when the selection size changes.
- **Translation Background Opacity**: Adjusts how visible the translation background is in the mirror window.
- **Zoom Out** (`⌘-`), **Actual Size** (`⌘0`), **Zoom In** (`⌘=`): Adjusts the mirror display scale.
- **Trim Empty Space** (`⌘9`): Reduces excess space in the mirror window while preserving the image size.

### Adjust the Overlay

- The opacity of the translation display area can be adjusted separately for active and inactive states.
- The opacity of the toolbar can be adjusted separately for active and inactive states.
- When **Ignore Mouse Events in Selection** (`⌘6`) is enabled, the overlay does not intercept mouse input and passes it to the app behind it. It is enabled by default.

### Dock the Mirror Window

The mirror window can be docked above, below, to the left, or to the right of the selected area.

- **Dock Top** (`⌘↑`)
- **Dock Bottom** (`⌘↓`)
- **Dock Left** (`⌘←`)
- **Dock Right** (`⌘→`)

In Mirror mode, running the docking shortcut for the same direction again undocks the window. In Overlay mode, docking buttons and the docking menu are hidden, but pressing a direction shortcut switches to Mirror mode and docks the window in that direction. `W`, `S`, `A`, and `D` can be used without modifier keys on the area-selection screen, and pressing a direction key while previewing in Overlay switches to a mirror docking preview in the same way.

## 5. Translation Refresh and Capture Target

### Automatic and Manual Refresh

The default is **Automatic Refresh**. When a screen change is detected, the current selection is recognized and translated again.

- Use **Switch Refresh Mode** (`⌘5`) on the toolbar to switch between automatic and manual refresh.
- In automatic refresh, use **Pause/Resume/Translate Now** (`Space`) to pause and resume translation.
- In manual refresh, use **Pause/Resume/Translate Now** (`Space`) to translate the current area.
- **Translate Now** (`⌘⌥1`) immediately captures and translates the current area.

### Choose Capture App

You can specify an app in **Choose Capture App** (`⌘1`) on the toolbar to use it as the translation target. Only apps behind the selected area can be selected.

### Track Target App Movement

Enable `Settings → Capture & OCR → Capture → Track Target App Movement` to move the translation area along with the target app window when it moves.

## 6. Using Translation Results

### Select and Copy Text

- Enable **Selection Mode** (`⌘D`) to select recognized source text and translations.
- **Select All** (`⌘A`): Selects all currently recognized text and translations.
- **Copy Selection** (`⌘C`): Copies the selected text.
- **Copy and Deselect** (`⌘X`): Copies the selected text and then clears the selection.
- **Copy All** (`⇧⌘C`): Copies all source text and translations in reading order.
- **Search Text** (`⌘F`): Searches the currently recognized text and translations.

### Copy and Save Images

- **Copy Image** (`⌃⌘C`): Copies an image of the current translation area to the clipboard.
- **Save Image** (`⌘S`): Saves an image of the current translation area as a PNG file.
- The image save folder and filename pattern can be changed in `Settings → Capture & OCR → Capture`.

The following tokens can be used in the filename pattern.

`{yyyy}`, `{MM}`, `{dd}`, `{HH}`, `{mm}`, `{ss}`, `{counter}`

### Protect Non-Source Text

When `Protect Non-Source Text` is enabled, English, the opposite language, and numbers outside the source language are excluded from translation and kept unchanged. As a result, the text is split and the translation context may be divided.

When this feature is disabled, the full mixed text is processed as one translation unit, which can preserve context, but English, the opposite language, and numbers may also be translated or changed. The default is off.

## 7. Settings

Choose **Settings…** (`⌘,`) from the Rearview icon in the menu bar.

### General

| Setting | Description |
| --- | --- |
| Launch at macOS Login | Launches Rearview automatically after login. |
| Display Language | Selects the language used for menus, settings, and the translation UI. |
| Translation Direction | Selects the source and output languages for translation. The default is Japanese→Korean. |
| Protect Non-Source Text | Excludes English, the opposite language, and numbers from translation. |
| Automatically Check for Updates | Checks for new updates in the background once a day. |
| Automatically Download and Install Updates | Downloads updates and installs them the next time the app quits. |
| **Reset All Settings** | Restores shortcut, display, capture, OCR, and update settings to their defaults. macOS permissions are not changed. |

### Shortcuts

In Shortcut settings, you can change or remove global shortcuts, translation session controls, text selection, mirror size, and area-selection shortcuts. If a new shortcut is already in use, **Already Used — Try Again** is displayed.

### Display

You can adjust the mirror and overlay display modes, the mirror window's always-on-top setting, background opacity, selection-size linking, overlay mouse input, and selection-area border opacity.

### Capture & OCR

| Setting | Description |
| --- | --- |
| Capture Frame Rate | The rate at which screen changes are checked. Range: 1–30 fps. |
| Track Target App Movement | Moves the translation area when the target app window moves. |
| Image Save Folder | The default folder for saved PNG files. |
| Image Filename Pattern | The filename format used for saved images. |
| Minimum OCR Interval | The minimum time before starting the next OCR after the screen changes. Range: 100–2000 ms. |
| Mirror Update Style | Displays translations all at once or progressively as lines complete. |
| OCR Execution Mode | Selects the OCR flow used in automatic and manual modes. |
| Recognition Language | Selects the order of Japanese, Korean, and English passed to OCR. |
| Low-Confidence Line Filter | The threshold for excluding OCR lines with low confidence. |

Change advanced OCR settings only when adjusting recognition results or processing time. In general use, keeping the defaults is recommended.

## 8. Default Shortcuts

Shortcuts can be changed in `Settings → Shortcuts`. The table below shows the defaults.

### Global Shortcuts

| Action | Default Shortcut |
| --- | --- |
| **Select Area** | `⌘⇧1` |
| **Translate Now** | `⌘⌥1` |
| **Activate Translation Display** | `⌃⌥1` |

### Translation Session and Display Controls

| Action | Default Shortcut |
| --- | --- |
| **Open Settings** | `⌘,` |
| **Stop Translation** | `⌘W` |
| **Choose Capture App** | `⌘1` |
| **Switch Mirror/Overlay Mode** | `⌘2` |
| **Switch Translation Direction** | `⌘3` |
| **Toggle Non-Source Text Protection** | `⌘4` |
| **Switch Automatic/Manual Refresh** | `⌘5` |
| **Toggle Mode-Specific Display Action** | `⌘6` |
| **Pause/Resume/Translate Now** | `Space` |

### Text and Images

| Action | Default Shortcut |
| --- | --- |
| **Select All** | `⌘A` |
| **Copy Selection** | `⌘C` |
| **Copy and Deselect** | `⌘X` |
| **Copy All** | `⇧⌘C` |
| **Copy Image** | `⌃⌘C` |
| **Save Image** | `⌘S` |
| **Search Text** | `⌘F` |
| **Toggle Selection Mode** | `⌘D` |

### Mirror Size and Position

| Action | Default Shortcut |
| --- | --- |
| **Zoom Out** | `⌘-` |
| **Actual Size** | `⌘0` |
| **Zoom In** | `⌘=` |
| **Trim Empty Space** | `⌘9` |
| **Follow Selection Size** | `⌘8` |
| **Dock Top** | `⌘↑` |
| **Dock Bottom** | `⌘↓` |
| **Dock Left** | `⌘←` |
| **Dock Right** | `⌘→` |

### Area Selection Single-Key Shortcuts

The following single-key shortcuts can be used while selecting an area. These shortcuts are configured separately from the shortcuts for a running translation session.

| Action | Default Key |
| --- | --- |
| **Switch Mirror/Overlay Mode** | `2` |
| **Dock Top** | `W` |
| **Dock Bottom** | `S` |
| **Dock Left** | `A` |
| **Dock Right** | `D` |

Even in Overlay mode, pressing a direction key switches to Mirror mode and docks the window in that direction. Docking buttons and the docking menu are not shown in Overlay mode.

## 9. Troubleshooting

### The App Does Not Launch

If macOS displays a security warning, launch the app once, then allow it to run from **System Settings → Privacy & Security → Open Anyway**.

### A Screen Recording Permission Error Appears

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Enable permission for Rearview.
3. Quit Rearview completely and relaunch it.

### Translation Does Not Start

- Make sure the selected area is within one display.
- Make sure the selected area is not too small and that the text is not clipped.
- Make sure the Japanese and Korean translation language packs are ready.
- If you specified a capture app, make sure that app is running.
- If there is no screen change, make sure automatic refresh is not paused.

### Text Is Not Recognized Well

- Select a slightly larger area containing the text.
- If there is a lot of small or blurry text, adjust the input scale in Advanced OCR.
- Set the `Recognition Language` order to match the main language on screen.
- Make sure the Low-Confidence Line Filter value is not set too high.

### The Overlay Blocks Clicks in the App Behind It

Check that `Settings → Display → Overlay → Ignore Mouse Events in Selection` is enabled. You can also toggle it with **Toggle Mode-Specific Display Action** (`⌘6`) on the toolbar.

### The Translation Area Does Not Follow a Moved Target App

Enable `Settings → Capture & OCR → Capture → Track Target App Movement`, and make sure the correct capture app is specified.

### An Image Cannot Be Saved

Make sure the image save folder exists and is writable. You can select another folder in `Settings → Capture & OCR → Capture → Image Save Folder`.

### A Shortcut Cannot Be Assigned

Make sure another feature or app is not using the shortcut. If **Already Used — Try Again** appears in the settings window, enter another key combination. If necessary, use **Reset All Settings** to restore Rearview's shortcuts to their defaults.
