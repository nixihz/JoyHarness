import Combine
import Foundation
import SwiftUI

@MainActor
final class SlotShortcutSettings: ObservableObject {
    static let storageKey = "slotKeyboardShortcuts"
    @Published private(set) var shortcuts: [Int: RecordedKeyboardShortcut]
    @Published var errors: [Int: String] = [:]
    var onChange: (() -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let stored = userDefaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Int: RecordedKeyboardShortcut].self, from: $0) } ?? [:]
        shortcuts = stored.filter { (0..<6).contains($0.key) }
    }

    func setShortcut(_ shortcut: RecordedKeyboardShortcut?, for slot: Int) {
        guard (0..<6).contains(slot) else { return }
        if let shortcut {
            guard shortcut.modifiers.contains(where: { [.command, .control, .option].contains($0) }) else {
                errors[slot] = L10n.text("录制到 \(shortcut.recorderDisplayName)，请同时按住 ⌘、⌃ 或 ⌥ 中至少一个修饰键。", "Recorded \(shortcut.recorderDisplayName). Hold at least one of ⌘, ⌃ or ⌥ with the key.")
                return
            }
            guard !shortcut.modifiers.contains(.function) else {
                errors[slot] = L10n.text("录制到 \(shortcut.recorderDisplayName)，其中包含系统上报的 fn 标记，暂不支持此组合。", "Recorded \(shortcut.recorderDisplayName), including a system-reported fn flag. This combination is not supported.")
                return
            }
            if let duplicate = shortcuts.first(where: {
                $0.key != slot && $0.value.keyCode == shortcut.keyCode
                    && Set($0.value.modifiers) == Set(shortcut.modifiers)
            }) {
                errors[slot] = L10n.text("该快捷键已用于槽位 \(duplicate.key + 1)。", "This shortcut is assigned to slot \(duplicate.key + 1).")
                return
            }
        }
        shortcuts[slot] = shortcut
        errors[slot] = nil
        if let data = try? JSONEncoder().encode(shortcuts) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
        onChange?()
    }
}

struct SlotShortcutSettingsPane: View {
    @ObservedObject var settings: SlotShortcutSettings
    @State private var recordingSlot: Int?

    var body: some View {
        Form {
            Section(L10n.text("槽位快捷键", "Slot Shortcuts")) {
                Text(L10n.text("为六个槽位分别设置全局快捷键，默认不设置。应用在后台时也可使用；切换任务需要连接适配器。", "Set a global shortcut for each of the six slots. None are assigned by default. Works in the background; switching tasks requires an adapter."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(0..<6, id: \.self) { slot in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(L10n.text("槽位 \(slot + 1)", "Slot \(slot + 1)"))
                            Spacer()
                            ShortcutRecorderButton(
                                shortcut: settings.shortcuts[slot],
                                isRecording: Binding(
                                    get: { recordingSlot == slot },
                                    set: { setRecording($0 ? slot : nil) }
                                )
                            ) { shortcut in
                                // Restore registrations before validation so errors remain visible.
                                setRecording(nil)
                                settings.setShortcut(shortcut, for: slot)
                            }
                            .frame(width: 180, height: 26)
                            Button(L10n.text("清除", "Clear")) {
                                setRecording(nil)
                                settings.setShortcut(nil, for: slot)
                            }
                            .disabled(settings.shortcuts[slot] == nil)
                        }
                        if let error = settings.errors[slot] {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                if recordingSlot != nil {
                    Button(L10n.text("取消录制", "Cancel Recording")) { setRecording(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { setRecording(nil) }
    }

    private func setRecording(_ slot: Int?) {
        recordingSlot = slot
        settings.onRecordingChange?(slot != nil)
    }
}
