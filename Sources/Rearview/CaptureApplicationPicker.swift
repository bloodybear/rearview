import AppKit
@preconcurrency import ScreenCaptureKit

struct CaptureTargetResolution: Equatable {
    let target: CaptureTarget
    let candidate: CaptureApplication?
}

func subtracting(_ occluder: CGRect, from rect: CGRect) -> [CGRect] {
    let intersection = rect.intersection(occluder)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
        return [rect]
    }
    var pieces: [CGRect] = []
    if intersection.minY > rect.minY {
        pieces.append(CGRect(x: rect.minX, y: rect.minY,
                             width: rect.width, height: intersection.minY - rect.minY))
    }
    if intersection.maxY < rect.maxY {
        pieces.append(CGRect(x: rect.minX, y: intersection.maxY,
                             width: rect.width, height: rect.maxY - intersection.maxY))
    }
    if intersection.minX > rect.minX {
        pieces.append(CGRect(x: rect.minX, y: intersection.minY,
                             width: intersection.minX - rect.minX, height: intersection.height))
    }
    if intersection.maxX < rect.maxX {
        pieces.append(CGRect(x: intersection.maxX, y: intersection.minY,
                             width: rect.maxX - intersection.maxX, height: intersection.height))
    }
    return pieces.filter { $0.width >= 1 && $0.height >= 1 }
}

/// `windows` must be ordered front to back.
func visibleCaptureApplications(
    windows: [(application: CaptureApplication, frame: CGRect)],
    intersecting selection: CGRect
) -> [CaptureApplication] {
    var occluders: [CGRect] = []
    var visible: [CaptureApplication] = []
    for window in windows {
        let clipped = window.frame.intersection(selection)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { continue }
        var uncovered = [clipped]
        for occluder in occluders {
            uncovered = uncovered.flatMap { subtracting(occluder, from: $0) }
            if uncovered.isEmpty { break }
        }
        if !uncovered.isEmpty { visible.append(window.application) }
        occluders.append(clipped)
    }
    return visible
}

func resolveCaptureTarget(
    windows: [(application: CaptureApplication, frame: CGRect)],
    intersecting selection: CGRect
) -> CaptureTargetResolution {
    let visible = visibleCaptureApplications(windows: windows, intersecting: selection)
    guard visible.count == 1, let application = visible.first else {
        return CaptureTargetResolution(target: .allContent, candidate: visible.first)
    }
    return CaptureTargetResolution(target: .application(application), candidate: application)
}

func screenCaptureRect(
    for selection: CGRect, screenFrame: CGRect, displayBounds: CGRect
) -> CGRect {
    CGRect(
        x: displayBounds.minX + selection.minX - screenFrame.minX,
        y: displayBounds.minY + screenFrame.maxY - selection.maxY,
        width: selection.width,
        height: selection.height
    )
}

func appKitSelectionRect(
    for captureRect: CGRect, screenFrame: CGRect, displayBounds: CGRect
) -> CGRect {
    CGRect(
        x: screenFrame.minX + captureRect.minX - displayBounds.minX,
        y: screenFrame.maxY - (captureRect.minY - displayBounds.minY) - captureRect.height,
        width: captureRect.width,
        height: captureRect.height
    )
}

@MainActor
final class CaptureApplicationPicker {
    func applications(for selection: CGRect, on screen: NSScreen) async throws -> [CaptureApplication] {
        let windows = try await visibleWindows(for: selection, on: screen)
        var seen = Set<pid_t>()
        return visibleCaptureApplications(windows: windows.windows, intersecting: windows.selection)
            .filter { seen.insert($0.processID).inserted }
    }

    func resolveTarget(for selection: CGRect, on screen: NSScreen) async throws -> CaptureTargetResolution {
        let result = try await visibleWindows(for: selection, on: screen)
        return resolveCaptureTarget(windows: result.windows, intersecting: result.selection)
    }

    private func visibleWindows(
        for selection: CGRect, on screen: NSScreen
    ) async throws -> (windows: [(application: CaptureApplication, frame: CGRect)], selection: CGRect) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw TranslatorError.noDisplay
        }
        let displayID = number.uint32Value
        let selectionInCaptureCoordinates = screenCaptureRect(
            for: selection, screenFrame: screen.frame, displayBounds: CGDisplayBounds(displayID)
        )
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let orderedWindowIDs = frontToBackWindowIDs()
        let order = Dictionary(uniqueKeysWithValues: orderedWindowIDs.enumerated().map { ($1, $0) })
        let ownPID = getpid()
        let shareableWindows = content.windows.filter { window in
            window.isOnScreen && window.windowLayer == 0
                && window.owningApplication?.processID != ownPID
                && window.owningApplication != nil
        }.sorted {
            (order[$0.windowID] ?? Int.max) < (order[$1.windowID] ?? Int.max)
        }
        let windows = shareableWindows.compactMap { window -> (CaptureApplication, CGRect)? in
            guard let owner = window.owningApplication else { return nil }
            return (CaptureApplication(
                processID: owner.processID,
                bundleIdentifier: owner.bundleIdentifier,
                name: owner.applicationName,
                anchorWindowID: window.windowID,
                anchorWindowFrame: window.frame
            ), window.frame)
        }
        return (windows, selectionInCaptureCoordinates)
    }

    private func frontToBackWindowIDs() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }
}
