import AppKit
import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct SlotShortcutSettingsTests {
    @Test
    func recordsAllFourModifiersWithoutFunctionForEachNumberKey() throws {
        let suite = "SlotShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SlotShortcutSettings(userDefaults: defaults)
        let keyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22]
        for (slot, keyCode) in keyCodes.enumerated() {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
            event.flags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
            let shortcut = RecordedKeyboardShortcut(event: try #require(NSEvent(cgEvent: event)))
            #expect(Set(shortcut.modifiers) == [.command, .shift, .option, .control])
            settings.setShortcut(shortcut, for: slot)
            #expect(settings.shortcuts[slot] == shortcut)
            #expect(settings.errors[slot] == nil)
        }
    }

    @Test
    func shortcutsDefaultToEmptyAndPersistEditsAndClearing() throws {
        let suite = "SlotShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SlotShortcutSettings(userDefaults: defaults)
        #expect(settings.shortcuts.isEmpty)
        var changes = 0
        settings.onChange = { changes += 1 }
        for slot in 0..<6 {
            let shortcut = RecordedKeyboardShortcut(keyCode: UInt16(slot), keyName: "Test", modifiers: [.control, .command])
            settings.setShortcut(shortcut, for: slot)
        }
        #expect(changes == 6)
        #expect(SlotShortcutSettings(userDefaults: defaults).shortcuts == settings.shortcuts)
        settings.setShortcut(nil, for: 3)
        let restored = SlotShortcutSettings(userDefaults: defaults)
        #expect(restored.shortcuts[3] == nil)
        #expect(restored.shortcuts.count == 5)
        #expect(changes == 7)
    }

    @Test
    func rejectsDuplicatePhysicalShortcutWithoutReplacingExistingAssignment() throws {
        let suite = "SlotShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SlotShortcutSettings(userDefaults: defaults)
        let first = RecordedKeyboardShortcut(keyCode: 18, keyName: "1", modifiers: [.command, .shift])
        let second = RecordedKeyboardShortcut(keyCode: 19, keyName: "2", modifiers: [.command, .shift])
        settings.setShortcut(first, for: 0)
        settings.setShortcut(second, for: 1)
        settings.setShortcut(RecordedKeyboardShortcut(keyCode: 18, keyName: "!", modifiers: [.shift, .command]), for: 1)
        #expect(settings.shortcuts[1] == second)
        #expect(settings.errors[1] != nil)
        #expect(SlotShortcutSettings(userDefaults: defaults).shortcuts[1] == second)
    }

    @Test
    func rejectsUnmodifiedKeysAndUnsupportedFunctionModifier() throws {
        let suite = "SlotShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SlotShortcutSettings(userDefaults: defaults)
        for modifiers: [RecordedShortcutModifier] in [[], [.shift], [.command, .function]] {
            settings.setShortcut(RecordedKeyboardShortcut(keyCode: 18, keyName: "1", modifiers: modifiers), for: 0)
            #expect(settings.shortcuts.isEmpty)
            #expect(settings.errors[0] != nil)
        }
    }
}
