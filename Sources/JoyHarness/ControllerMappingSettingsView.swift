import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ControllerMappingSettingsPane: View {
    @ObservedObject var store: ControllerMappingStore
    @State private var isResetConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ControllerInputGroup.allCases) { group in
                    Section(group.displayName) {
                        ForEach(inputs(in: group)) { input in
                            VStack(alignment: .leading, spacing: 8) {
                                Picker(store.displayName(for: input), selection: binding(for: input)) {
                                    ForEach(input.availableActions) { action in
                                        Text(action.displayName).tag(action)
                                    }
                                }
                                .pickerStyle(.menu)

                                if store.action(for: input) == .openApplication {
                                    openApplicationRow(for: input)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Label(L10n.text("恢复默认映射", "Restore Default Mappings"), systemImage: "arrow.counterclockwise")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(.bar)
        }
        .alert(L10n.text("恢复默认映射？", "Restore Default Mappings?"), isPresented: $isResetConfirmationPresented) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("恢复默认", "Restore Defaults"), role: .destructive) {
                store.resetDefaults()
            }
        } message: {
            Text(L10n.text(
                "当前的所有自定义按键设置将被替换。",
                "All custom button mappings will be replaced."
            ))
        }
    }

    @ViewBuilder
    private func openApplicationRow(for input: ControllerInput) -> some View {
        HStack(spacing: 8) {
            Text(
                store.openApplicationDisplayName(for: input)
                    ?? L10n.text("未选择应用", "No application selected")
            )
            .foregroundStyle(store.openApplicationTarget(for: input) == nil ? .secondary : .primary)
            .lineLimit(1)

            Spacer(minLength: 8)

            Button(L10n.text("选择…", "Choose…")) {
                chooseApplication(for: input)
            }

            if store.openApplicationTarget(for: input) != nil {
                Button(L10n.text("清除", "Clear")) {
                    store.setOpenApplicationTarget(nil, for: input)
                }
            }
        }
        .font(.caption)
    }

    private func inputs(in group: ControllerInputGroup) -> [ControllerInput] {
        ControllerInput.allCases.filter { input in
            guard input.group == group else { return false }
            if input == .touchpadButton {
                return store.controllerFamily == .dualSense || store.controllerFamily == .dualShock
            }
            return true
        }
    }

    private func binding(for input: ControllerInput) -> Binding<ControllerMappedAction> {
        Binding(
            get: { store.action(for: input) },
            set: { store.setAction($0, for: input) }
        )
    }

    private func chooseApplication(for input: ControllerInput) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("选择", "Choose")
        panel.message = L10n.text(
            "选择要由此按键打开的应用。",
            "Choose the application this input should open."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
            ?? FileManager.default.displayName(atPath: url.path)
        store.setOpenApplicationTarget(bundleIdentifier, for: input)
        if store.action(for: input) != .openApplication {
            store.setAction(.openApplication, for: input)
        }
    }
}
