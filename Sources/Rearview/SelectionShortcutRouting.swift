import AppKit

@MainActor
func isSelectionCommandSurfaceWindow(_ window: NSWindow, excluding internalWindow: NSWindow?) -> Bool {
    window !== internalWindow && window.isVisible && (window.canBecomeKey || window.canBecomeMain)
}

func shouldPresentSelectionCommandSurface(isActive: Bool, permissionReady: Bool,
    isSelecting: Bool, sessionActive: Bool, hasUserWindow: Bool, isBenchmark: Bool) -> Bool {
    isActive && permissionReady && !isSelecting && !sessionActive && !hasUserWindow && !isBenchmark
}

/// Registered Carbon hotkeys and application-local key events are separate
/// delivery paths. Both must invoke the same configured selection command.
@MainActor
func handleLocalSelectionShortcut(_ event: NSEvent, hotKey: SelectionHotKey,
    isActive: Bool, isRecording: Bool, isSelecting: Bool, perform: () -> Void) -> Bool {
    guard isActive, !isRecording, !isSelecting, hotKey.isEnabled,
          event.type == .keyDown,
          matchesLocalShortcut(eventKeyCode: event.keyCode, eventModifiers: event.modifierFlags,
            shortcutKeyCode: hotKey.keyCode, shortcutModifiers: hotKey.modifiers) else { return false }
    if !event.isARepeat { perform() }
    return true
}
