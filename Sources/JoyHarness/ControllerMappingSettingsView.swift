import SwiftUI

struct ControllerMappingSettingsPane: View {
    @ObservedObject var store: ControllerMappingStore
    @State private var isResetConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ControllerInputGroup.allCases) { group in
                    Section(group.displayName) {
                        ForEach(inputs(in: group)) { input in
                            Picker(store.displayName(for: input), selection: binding(for: input)) {
                                ForEach(input.availableActions) { action in
                                    Text(action.displayName).tag(action)
                                }
                            }
                            .pickerStyle(.menu)
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
            .padding(16)
            .background(.bar)
        }
        .navigationTitle(L10n.text("按键映射", "Controller Mapping"))
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
}
