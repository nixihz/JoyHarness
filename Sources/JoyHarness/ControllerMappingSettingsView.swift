import SwiftUI

struct ControllerMappingSettingsView: View {
    @ObservedObject var store: ControllerMappingStore
    @State private var isResetConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ControllerInputGroup.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(inputs(in: group)) { input in
                            Picker(input.displayName, selection: binding(for: input)) {
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
                    Label("恢复默认映射", systemImage: "arrow.counterclockwise")
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .navigationTitle("按键映射")
        .alert("恢复默认映射？", isPresented: $isResetConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                store.resetDefaults()
            }
        } message: {
            Text("当前的所有自定义按键设置将被替换。")
        }
    }

    private func inputs(in group: ControllerInputGroup) -> [ControllerInput] {
        ControllerInput.allCases.filter { $0.group == group }
    }

    private func binding(for input: ControllerInput) -> Binding<ControllerMappedAction> {
        Binding(
            get: { store.action(for: input) },
            set: { store.setAction($0, for: input) }
        )
    }
}
