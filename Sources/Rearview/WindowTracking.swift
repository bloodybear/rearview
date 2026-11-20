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

struct WindowTrackingInsets: Equatable {
    let left: CGFloat
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat

    init(captureRect: CGRect, windowFrame: CGRect) {
        left = captureRect.minX - windowFrame.minX
        top = captureRect.minY - windowFrame.minY
        right = windowFrame.maxX - captureRect.maxX
        bottom = windowFrame.maxY - captureRect.maxY
    }
}

func projectTrackedSelection(
    insets: WindowTrackingInsets,
    windowFrame: CGRect,
    displays: [WindowTrackingDisplay],
    preferredDisplayID: CGDirectDisplayID? = nil
) -> WindowTrackingProjection? {
    guard !displays.isEmpty else { return nil }

    let left = windowFrame.minX + insets.left
    let right = windowFrame.maxX - insets.right
    let top = windowFrame.minY + insets.top
    let bottom = windowFrame.maxY - insets.bottom
    let desiredWidth = right - left
    let desiredHeight = bottom - top
    let center = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
    let desired = CGRect(x: center.x - max(0, desiredWidth) / 2,
                         y: center.y - max(0, desiredHeight) / 2,
                         width: max(0, desiredWidth), height: max(0, desiredHeight))
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
    let wasResized = abs(width - desiredWidth) > 0.01
        || abs(height - desiredHeight) > 0.01

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
