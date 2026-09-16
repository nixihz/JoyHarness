import Carbon

/// Global task-slot shortcuts, available even when Joy Harness is in the background.
@MainActor
final class SlotHotkeys {
    private static let signature: OSType = 0x4A48534C // JHSL
    private var handler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef] = []
    var onSelectSlot: ((Int) -> Void)?

    func start(shortcuts: [Int: RecordedKeyboardShortcut]) -> [Int: String] {
        stop()
        var errors: [Int: String] = [:]
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID
                )
                guard status == noErr else { return status }
                return MainActor.assumeIsolated {
                    guard hotkeyID.signature == SlotHotkeys.signature,
                          (1...6).contains(hotkeyID.id) else {
                        return OSStatus(eventNotHandledErr)
                    }
                    let owner = Unmanaged<SlotHotkeys>.fromOpaque(context).takeUnretainedValue()
                    owner.onSelectSlot?(Int(hotkeyID.id) - 1)
                    return noErr
                }
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard status == noErr else {
            print("[agent-deck] could not install slot hotkey handler: \(status)")
            return shortcuts.mapValues { _ in L10n.text("无法启用全局快捷键", "Could not enable global shortcuts") }
        }

        // Register only shortcuts explicitly configured by the user.
        for (index, shortcut) in shortcuts.sorted(by: { $0.key < $1.key }) {
            guard (0..<6).contains(index) else { continue }
            let modifiers = shortcut.modifiers.reduce(UInt32(0)) { result, modifier in
                let flag = switch modifier {
                case .command: cmdKey
                case .shift: shiftKey
                case .option: optionKey
                case .control: controlKey
                case .function: 0
                }
                return result | UInt32(flag)
            }
            var hotkey: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode), modifiers,
                EventHotKeyID(signature: Self.signature, id: UInt32(index + 1)),
                GetApplicationEventTarget(), 0, &hotkey
            )
            if status == noErr, let hotkey {
                hotkeys.append(hotkey)
            } else {
                errors[index] = L10n.text("快捷键不可用，可能已被其他应用占用，请更换。", "Shortcut unavailable; it may be in use by another app. Choose another.")
                print("[agent-deck] could not register slot \(index + 1) hotkey: \(status)")
            }
        }
        return errors
    }

    func stop() {
        for hotkey in hotkeys { UnregisterEventHotKey(hotkey) }
        hotkeys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
