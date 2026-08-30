import AppKit

let minimumTrackedSelectionSize = CGSize(width: 32, height: 20)

struct WindowTrackingDisplay: Equatable {
    let displayID: CGDirectDisplayID
    let bounds: CGRect
}

struct WindowTrackingProjection: Equatable {
    let captureRect: CGRect
    let displayID: CGDirectDisplayID
    let wasResized: Bool
}

func relativeSelectionInWindow(
    selection: CGRect, screenFrame: CGRect, displayBounds: CGRect, windowFrame: CGRect
) -> CGRect {
    let captureRect = screenCaptureRect(
        for: selection, screenFrame: screenFrame, displayBounds: displayBounds
    )
    return captureRect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
}

func projectTrackedSelection(
    relativeSelection: CGRect,
    windowFrame: CGRect,
    displays: [WindowTrackingDisplay],
    preferredDisplayID: CGDirectDisplayID? = nil
) -> WindowTrackingProjection? {
    guard !displays.isEmpty else { return nil }

    let desired = relativeSelection.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY)
    let selectedDisplay = displays.first(where: { $0.bounds.contains(desired) })
        ?? displays.first(where: { $0.bounds.contains(desired.center) })
        ?? displays.first(where: { $0.displayID == preferredDisplayID })
    guard let selectedDisplay else { return nil }

    let availableWidth = selectedDisplay.bounds.width
    let availableHeight = selectedDisplay.bounds.height
    guard availableWidth >= minimumTrackedSelectionSize.width,
          availableHeight >= minimumTrackedSelectionSize.height else {
        return nil
    }

    let width = max(
        minimumTrackedSelectionSize.width,
        min(desired.width, availableWidth)
    )
    let height = max(
        minimumTrackedSelectionSize.height,
        min(desired.height, availableHeight)
    )
    let wasResized = abs(width - desired.width) > 0.01
        || abs(height - desired.height) > 0.01

    var projected = CGRect(
        x: desired.midX - width / 2,
        y: desired.midY - height / 2,
        width: width,
        height: height
    )
    projected.origin.x = min(
        max(selectedDisplay.bounds.minX, projected.minX),
        selectedDisplay.bounds.maxX - projected.width
    )
    projected.origin.y = min(
        max(selectedDisplay.bounds.minY, projected.minY),
        selectedDisplay.bounds.maxY - projected.height
    )
    return WindowTrackingProjection(
        captureRect: projected,
        displayID: selectedDisplay.displayID,
        wasResized: wasResized
    )
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
