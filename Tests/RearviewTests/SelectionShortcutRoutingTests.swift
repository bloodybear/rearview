import AppKit
import Carbon
import Testing
@testable import Rearview

@MainActor
struct SelectionShortcutRoutingTests {
    @Test func internalNonKeyPanelsDoNotCountAsUserCommandWindows() {
        let panel = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.orderBack(nil)
        window.orderFront(nil)
        defer { panel.orderOut(nil); window.orderOut(nil) }
        #expect(panel.isVisible)
        #expect(!isSelectionCommandSurfaceWindow(panel, excluding: nil))
        #expect(isSelectionCommandSurfaceWindow(window, excluding: panel))
        #expect(!isSelectionCommandSurfaceWindow(window, excluding: window))
        window.orderOut(nil)
        #expect(!isSelectionCommandSurfaceWindow(window, excluding: nil))
    }
    @Test func explicitActivationProvidesAUserWindowWithoutInterruptingExistingWork() {
        #expect(shouldPresentSelectionCommandSurface(isActive: true, permissionReady: true,
            isSelecting: false, sessionActive: false, hasUserWindow: false, isBenchmark: false))
        for state in [(false, true, false, false, false, false),
                      (true, false, false, false, false, false),
                      (true, true, true, false, false, false),
                      (true, true, false, true, false, false),
                      (true, true, false, false, true, false),
                      (true, true, false, false, false, true)] {
            #expect(!shouldPresentSelectionCommandSurface(isActive: state.0, permissionReady: state.1,
                isSelecting: state.2, sessionActive: state.3, hasUserWindow: state.4, isBenchmark: state.5))
        }
    }
    private func event(code: UInt16 = 18, flags: NSEvent.ModifierFlags = [.command, .shift],
                       repeatKey: Bool = false, type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "1",
            isARepeat: repeatKey, keyCode: code)!
    }

    @Test func configuredSelectionChordIsDeliveredLocallyOnce() {
        var count = 0, selecting = false
        let perform = { count += 1; selecting = true }
        #expect(handleLocalSelectionShortcut(event(), hotKey: .defaultValue, isActive: true,
            isRecording: false, isSelecting: selecting, perform: perform))
        #expect(!handleLocalSelectionShortcut(event(), hotKey: .defaultValue, isActive: true,
            isRecording: false, isSelecting: selecting, perform: perform))
        #expect(count == 1)
    }

    @Test func recordingInactiveDisabledAndUnmatchedInputRemainUntouched() {
        let key = SelectionHotKey.defaultValue
        let disabled = SelectionHotKey(keyCode: key.keyCode, modifiers: key.modifiers,
            keyLabel: key.keyLabel, isEnabled: false)
        for (active, recording, configured, input) in [
            (false, false, key, event()), (true, true, key, event()),
            (true, false, disabled, event()), (true, false, key, event(code: 19)),
            (true, false, key, event(flags: [.command])),
            (true, false, key, event(type: .keyUp))] {
            #expect(!handleLocalSelectionShortcut(input, hotKey: configured, isActive: active,
                isRecording: recording, isSelecting: false,
                perform: { Issue.record("Unexpected selection") }))
        }
    }

    @Test func repeatIsConsumedWithoutStartingAnotherSelection() {
        #expect(handleLocalSelectionShortcut(event(repeatKey: true), hotKey: .defaultValue,
            isActive: true, isRecording: false, isSelecting: false,
            perform: { Issue.record("Repeated selection") }))
    }

    @Test func remappedShortcutUsesPhysicalKeyAndConfiguredModifiers() {
        let key = SelectionHotKey(keyCode: 19, modifiers: UInt32(controlKey | optionKey), keyLabel: "2")
        var count = 0
        #expect(handleLocalSelectionShortcut(event(code: 19, flags: [.control, .option]), hotKey: key,
            isActive: true, isRecording: false, isSelecting: false, perform: { count += 1 }))
        #expect(count == 1)
    }
}
